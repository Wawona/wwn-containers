//! Minimal OCI/Docker Registry v2 client: token (Bearer) auth negotiation,
//! manifest/index fetch with digest capture, and streaming blob download.

use std::io::Read;

use serde::Deserialize;

use crate::digest::Digest;
use crate::error::OciError;
use crate::reference::Reference;

/// Optional static credentials for private registries (Basic during the token
/// exchange, or a pre-issued bearer token).
#[derive(Clone, Default)]
pub struct Credentials {
    pub username: Option<String>,
    pub password: Option<String>,
    pub bearer: Option<String>,
}

pub struct RegistryClient {
    agent: ureq::Agent,
    creds: Credentials,
    /// Cache the negotiated bearer per scope so repeated blob GETs reuse it.
    cached_token: Option<String>,
}

/// A fetched manifest document plus the metadata needed to address it.
pub struct FetchedManifest {
    pub bytes: Vec<u8>,
    pub media_type: String,
    pub digest: Digest,
}

#[derive(Deserialize)]
struct TokenResponse {
    #[serde(default)]
    token: Option<String>,
    #[serde(default, rename = "access_token")]
    access_token: Option<String>,
}

impl RegistryClient {
    pub fn new(creds: Credentials) -> Self {
        let agent = ureq::AgentBuilder::new()
            .user_agent(concat!("wwn-oci/", env!("CARGO_PKG_VERSION")))
            .build();
        RegistryClient { agent, creds, cached_token: None }
    }

    /// Fetch a manifest or index for `reference.manifest_ref()`.
    pub fn get_manifest(&mut self, reference: &Reference) -> Result<FetchedManifest, OciError> {
        let url = format!("{}/manifests/{}", reference.base_url(), reference.manifest_ref());
        let accept = crate::spec::media_type::accept_all();
        let resp = self.authorized_get(&url, reference, Some(&accept))?;

        let media_type = resp
            .header("Content-Type")
            .map(|s| s.split(';').next().unwrap_or(s).trim().to_string())
            .unwrap_or_else(|| crate::spec::media_type::OCI_MANIFEST.to_string());
        let content_digest = resp.header("Docker-Content-Digest").map(str::to_string);

        let mut bytes = Vec::new();
        resp.into_reader().read_to_end(&mut bytes)?;

        let digest = match content_digest {
            Some(d) => Digest::parse(&d)?,
            None => Digest::sha256_of(&bytes),
        };

        // If the reference pinned a digest, enforce it.
        if let Some(pinned) = &reference.digest {
            let pinned = Digest::parse(pinned)?;
            let actual = Digest::sha256_of(&bytes);
            if actual != pinned {
                return Err(OciError::DigestMismatch {
                    expected: pinned.to_string(),
                    actual: actual.to_string(),
                });
            }
        }

        Ok(FetchedManifest { bytes, media_type, digest })
    }

    /// Fetch a specific manifest by digest (used after selecting from an index).
    pub fn get_manifest_by_digest(
        &mut self,
        reference: &Reference,
        digest: &Digest,
    ) -> Result<FetchedManifest, OciError> {
        let child = Reference {
            registry: reference.registry.clone(),
            repository: reference.repository.clone(),
            tag: None,
            digest: Some(digest.to_string()),
        };
        self.get_manifest(&child)
    }

    /// Stream a blob (config or layer) by digest. Returns a boxed reader so the
    /// caller can pipe it straight into the CAS with digest verification.
    pub fn blob_reader(
        &mut self,
        reference: &Reference,
        digest: &Digest,
    ) -> Result<Box<dyn Read + Send>, OciError> {
        let url = format!("{}/blobs/{}", reference.base_url(), digest);
        let resp = self.authorized_get(&url, reference, None)?;
        Ok(Box::new(resp.into_reader()))
    }

    /// Perform a GET, negotiating a bearer token on 401 and retrying once.
    fn authorized_get(
        &mut self,
        url: &str,
        reference: &Reference,
        accept: Option<&str>,
    ) -> Result<ureq::Response, OciError> {
        match self.try_get(url, accept) {
            Ok(resp) => Ok(resp),
            Err(ureq::Error::Status(401, resp)) => {
                let challenge = resp
                    .header("WWW-Authenticate")
                    .ok_or_else(|| OciError::Auth("401 without WWW-Authenticate".into()))?
                    .to_string();
                let token = self.obtain_token(&challenge, reference)?;
                self.cached_token = Some(token);
                self.try_get(url, accept).map_err(map_transport)
            }
            Err(e) => Err(map_transport(e)),
        }
    }

    fn try_get(&self, url: &str, accept: Option<&str>) -> Result<ureq::Response, ureq::Error> {
        let mut req = self.agent.get(url);
        if let Some(a) = accept {
            req = req.set("Accept", a);
        }
        if let Some(bearer) = self.creds.bearer.as_ref().or(self.cached_token.as_ref()) {
            req = req.set("Authorization", &format!("Bearer {bearer}"));
        }
        req.call()
    }

    /// Parse a `Bearer realm=...,service=...,scope=...` challenge, call the auth
    /// endpoint, and return the token.
    fn obtain_token(&self, challenge: &str, reference: &Reference) -> Result<String, OciError> {
        let params = parse_bearer_challenge(challenge)
            .ok_or_else(|| OciError::Auth(format!("unsupported auth challenge: {challenge}")))?;
        let realm = params
            .realm
            .ok_or_else(|| OciError::Auth("challenge missing realm".into()))?;

        let scope = params
            .scope
            .unwrap_or_else(|| format!("repository:{}:pull", reference.repository));

        let mut req = self.agent.get(&realm);
        if let Some(service) = &params.service {
            req = req.query("service", service);
        }
        req = req.query("scope", &scope);
        if let (Some(u), Some(p)) = (&self.creds.username, &self.creds.password) {
            let basic = base64_encode(format!("{u}:{p}").as_bytes());
            req = req.set("Authorization", &format!("Basic {basic}"));
        }

        let resp = req.call().map_err(map_transport)?;
        let tok: TokenResponse = resp.into_json()?;
        tok.token
            .or(tok.access_token)
            .ok_or_else(|| OciError::Auth("token endpoint returned no token".into()))
    }
}

struct BearerParams {
    realm: Option<String>,
    service: Option<String>,
    scope: Option<String>,
}

fn parse_bearer_challenge(challenge: &str) -> Option<BearerParams> {
    let rest = challenge.strip_prefix("Bearer ").or_else(|| challenge.strip_prefix("bearer "))?;
    let mut realm = None;
    let mut service = None;
    let mut scope = None;
    for part in split_challenge_params(rest) {
        if let Some((k, v)) = part.split_once('=') {
            let v = v.trim().trim_matches('"').to_string();
            match k.trim() {
                "realm" => realm = Some(v),
                "service" => service = Some(v),
                "scope" => scope = Some(v),
                _ => {}
            }
        }
    }
    Some(BearerParams { realm, service, scope })
}

/// Split `k="v",k2="v2"` respecting quotes (scope values may contain commas).
fn split_challenge_params(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for c in s.chars() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                cur.push(c);
            }
            ',' if !in_quotes => {
                out.push(std::mem::take(&mut cur));
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn map_transport(e: ureq::Error) -> OciError {
    match e {
        ureq::Error::Status(code, resp) => {
            let message = resp.into_string().unwrap_or_default();
            OciError::Registry { status: code, message }
        }
        ureq::Error::Transport(t) => OciError::Transport(t.to_string()),
    }
}

/// Standard base64 (no external crate) for Basic auth headers.
fn base64_encode(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
        out.push(ALPHABET[((n >> 18) & 63) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { ALPHABET[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[(n & 63) as usize] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_challenge_with_comma_in_scope() {
        let c = r#"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull,push""#;
        let p = parse_bearer_challenge(c).unwrap();
        assert_eq!(p.realm.as_deref(), Some("https://auth.docker.io/token"));
        assert_eq!(p.service.as_deref(), Some("registry.docker.io"));
        assert_eq!(p.scope.as_deref(), Some("repository:library/alpine:pull,push"));
    }

    #[test]
    fn base64_matches_known_vector() {
        assert_eq!(base64_encode(b"user:pass"), "dXNlcjpwYXNz");
        assert_eq!(base64_encode(b"a"), "YQ==");
        assert_eq!(base64_encode(b"ab"), "YWI=");
    }
}
