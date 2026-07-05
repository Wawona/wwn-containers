//! Parse OCI image references into (registry, repository, tag-or-digest),
//! applying Docker Hub's implicit defaults (docker.io, `library/` namespace).

use crate::error::OciError;

const DEFAULT_REGISTRY: &str = "docker.io";
const DOCKER_HUB_HOST: &str = "registry-1.docker.io";
const DEFAULT_TAG: &str = "latest";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reference {
    /// Canonical registry host used for API calls (e.g. `registry-1.docker.io`).
    pub registry: String,
    /// Repository path, e.g. `library/alpine` or `myorg/app`.
    pub repository: String,
    /// A tag, if the reference used one (mutually exclusive-ish with digest).
    pub tag: Option<String>,
    /// A pinned digest, if the reference used `@sha256:...`.
    pub digest: Option<String>,
}

impl Reference {
    /// Parse strings like:
    ///   alpine
    ///   alpine:3.20
    ///   library/alpine:3.20
    ///   ghcr.io/foo/bar:tag
    ///   ghcr.io/foo/bar@sha256:...
    pub fn parse(input: &str) -> Result<Reference, OciError> {
        if input.is_empty() {
            return Err(OciError::Reference("empty reference".into()));
        }

        // Split off an @digest first (digests contain ':' so handle before tag).
        let (name_and_tag, digest) = match input.split_once('@') {
            Some((left, dig)) => (left, Some(dig.to_string())),
            None => (input, None),
        };

        // Determine whether the first path component is a registry host. Docker's
        // heuristic: it's a host if it contains '.' or ':' or is exactly
        // "localhost".
        let (registry_raw, remainder) = match name_and_tag.split_once('/') {
            Some((first, rest))
                if first == "localhost" || first.contains('.') || first.contains(':') =>
            {
                (first.to_string(), rest.to_string())
            }
            _ => (DEFAULT_REGISTRY.to_string(), name_and_tag.to_string()),
        };

        // Split repository:tag on the LAST ':' that is not part of a path.
        let (repository, tag) = match remainder.rsplit_once(':') {
            // A ':' that appears after the last '/' is a tag separator.
            Some((repo, tag)) if !tag.contains('/') => (repo.to_string(), Some(tag.to_string())),
            _ => (remainder.clone(), None),
        };

        // Docker Hub official images live under `library/`.
        let repository = if registry_raw == DEFAULT_REGISTRY && !repository.contains('/') {
            format!("library/{repository}")
        } else {
            repository
        };

        let registry = if registry_raw == DEFAULT_REGISTRY {
            DOCKER_HUB_HOST.to_string()
        } else {
            registry_raw
        };

        if repository.is_empty() {
            return Err(OciError::Reference(format!("no repository in {input:?}")));
        }

        // If neither tag nor digest given, default to :latest.
        let tag = if digest.is_none() && tag.is_none() {
            Some(DEFAULT_TAG.to_string())
        } else {
            tag
        };

        Ok(Reference { registry, repository, tag, digest })
    }

    /// The manifest reference used in the URL path: digest if pinned, else tag.
    pub fn manifest_ref(&self) -> &str {
        self.digest.as_deref().or(self.tag.as_deref()).unwrap_or(DEFAULT_TAG)
    }

    pub fn base_url(&self) -> String {
        // Registry v2 is always https except plain localhost/dev registries.
        let scheme = if self.registry.starts_with("localhost") { "http" } else { "https" };
        format!("{scheme}://{}/v2/{}", self.registry, self.repository)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hub_defaults() {
        let r = Reference::parse("alpine").unwrap();
        assert_eq!(r.registry, DOCKER_HUB_HOST);
        assert_eq!(r.repository, "library/alpine");
        assert_eq!(r.tag.as_deref(), Some("latest"));
        assert!(r.digest.is_none());
    }

    #[test]
    fn tagged_org() {
        let r = Reference::parse("myorg/app:1.2").unwrap();
        assert_eq!(r.repository, "myorg/app");
        assert_eq!(r.tag.as_deref(), Some("1.2"));
    }

    #[test]
    fn custom_registry_with_port_and_digest() {
        let r = Reference::parse("localhost:5000/team/svc@sha256:aa").unwrap();
        assert_eq!(r.registry, "localhost:5000");
        assert_eq!(r.repository, "team/svc");
        assert_eq!(r.digest.as_deref(), Some("sha256:aa"));
        assert!(r.tag.is_none());
        assert!(r.base_url().starts_with("http://"));
    }

    #[test]
    fn ghcr() {
        let r = Reference::parse("ghcr.io/foo/bar:tag").unwrap();
        assert_eq!(r.registry, "ghcr.io");
        assert_eq!(r.repository, "foo/bar");
        assert_eq!(r.manifest_ref(), "tag");
    }
}
