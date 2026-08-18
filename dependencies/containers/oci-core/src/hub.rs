//! Docker Hub search + tag listing.
//!
//! Docker Hub's JSON API is **not** part of the OCI distribution spec (the
//! registry v2 protocol has no search verb), but it is the discovery surface
//! Wawona's GUI and CLI need to find images. This client fetches **metadata
//! only** (repository/tag listings) over plain HTTPS, so it stays inside the
//! same compliance envelope as the rest of image management: pure userspace,
//! no code execution, safe on every target.
//!
//!   * search: `GET https://hub.docker.com/v2/search/repositories/?query=...`
//!   * tags:   `GET https://hub.docker.com/v2/repositories/<repo>/tags/`
//!
//! Both endpoints work anonymously (rate-limited) and are paginated.

use serde::{Deserialize, Serialize};

use crate::error::OciError;

/// One repository hit from a Docker Hub search.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchResult {
    #[serde(rename = "repo_name")]
    pub repo_name: String,
    /// The pullable registry reference for this hit. Not part of the Hub
    /// response — populated after deserialization so GUI/CLI consumers share
    /// one resolution rule (official single-component names live in `library/`).
    #[serde(default, rename = "pullableRef", skip_deserializing)]
    pub pullable_ref: String,
    #[serde(default, rename = "short_description")]
    pub short_description: String,
    #[serde(default, rename = "star_count")]
    pub star_count: u64,
    #[serde(default, rename = "pull_count")]
    pub pull_count: u64,
    #[serde(default, rename = "is_official")]
    pub is_official: bool,
    #[serde(default, rename = "is_automated")]
    pub is_automated: bool,
}

impl SearchResult {
    /// The pullable registry reference for this hit. Official single-component
    /// names live in Docker Hub's `library/` namespace.
    pub fn compute_pullable_ref(&self) -> String {
        let repo = if self.is_official && !self.repo_name.contains('/') {
            format!("library/{}", self.repo_name)
        } else {
            self.repo_name.clone()
        };
        format!("docker.io/{repo}")
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SearchResponse {
    pub count: u64,
    #[serde(default)]
    pub results: Vec<SearchResult>,
}

/// One tag hit from a Docker Hub repository.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TagResult {
    pub name: String,
    #[serde(default, rename = "full_size")]
    pub full_size: Option<u64>,
    #[serde(default, rename = "tag_last_pushed")]
    pub tag_last_pushed: Option<String>,
    #[serde(default)]
    pub images: Vec<TagImage>,
}

/// Per-architecture image record inside a tag hit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TagImage {
    #[serde(default)]
    pub architecture: String,
    #[serde(default)]
    pub os: String,
    #[serde(default)]
    pub digest: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TagsResponse {
    pub count: u64,
    #[serde(default)]
    pub results: Vec<TagResult>,
}

/// Thin client for Docker Hub's public JSON API (search + tags).
pub struct HubClient {
    agent: ureq::Agent,
}

impl HubClient {
    pub fn new() -> Self {
        let agent = ureq::AgentBuilder::new()
            .user_agent(concat!("wwn-oci/", env!("CARGO_PKG_VERSION")))
            .build();
        HubClient { agent }
    }

    /// Search Docker Hub repositories. `page` is 1-based; `page_size` is the
    /// number of hits per page (Hub caps it at 100).
    pub fn search_repositories(
        &self,
        query: &str,
        page: u32,
        page_size: u32,
    ) -> Result<SearchResponse, OciError> {
        let resp = self
            .agent
            .get("https://hub.docker.com/v2/search/repositories/")
            .query("query", query)
            .query("page", &page.to_string())
            .query("page_size", &page_size.to_string())
            .call()
            .map_err(map_hub_error)?;
        let mut resp: SearchResponse = resp.into_json()?;
        // Populate the pullable reference for every hit so JSON consumers get
        // the resolved registry reference without re-deriving the library/
        // namespace rule.
        for result in &mut resp.results {
            result.pullable_ref = result.compute_pullable_ref();
        }
        Ok(resp)
    }

    /// List tags of a Docker Hub repository (`python`, `circleci/python`, …).
    ///
    /// The Hub tags endpoint requires a namespace-qualified path, so a
    /// single-component name is treated as Docker Hub's official `library/`
    /// namespace (same shorthand `pull` uses), and a leading `docker.io/`
    /// registry host is stripped.
    pub fn list_tags(
        &self,
        repository: &str,
        page: u32,
        page_size: u32,
    ) -> Result<TagsResponse, OciError> {
        let repo = normalize_repo(repository);
        let url = format!("https://hub.docker.com/v2/repositories/{repo}/tags/");
        let resp = self
            .agent
            .get(&url)
            .query("page", &page.to_string())
            .query("page_size", &page_size.to_string())
            .call()
            .map_err(map_hub_error)?;
        Ok(resp.into_json()?)
    }
}

/// Map a user-supplied repository onto the Hub API's namespace-qualified path.
fn normalize_repo(repository: &str) -> String {
    let repo = repository.trim();
    let repo = repo
        .strip_prefix("docker.io/")
        .or_else(|| repo.strip_prefix("registry-1.docker.io/"))
        .unwrap_or(repo);
    if repo.contains('/') {
        repo.to_string()
    } else {
        format!("library/{repo}")
    }
}

impl Default for HubClient {
    fn default() -> Self {
        Self::new()
    }
}

fn map_hub_error(e: ureq::Error) -> OciError {
    match e {
        ureq::Error::Status(code, resp) => {
            let message = resp.into_string().unwrap_or_default();
            OciError::Registry {
                status: code,
                message,
            }
        }
        ureq::Error::Transport(t) => OciError::Transport(t.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_search_response() {
        let json = r#"{
            "count": 2,
            "results": [
                {
                    "repo_name": "python",
                    "short_description": "Python is an interpreted language.",
                    "star_count": 10510,
                    "pull_count": 9079671340,
                    "repo_owner": "",
                    "is_automated": false,
                    "is_official": true
                },
                {
                    "repo_name": "circleci/python",
                    "short_description": "",
                    "star_count": 116,
                    "pull_count": 216303061,
                    "repo_owner": "circleci",
                    "is_automated": false,
                    "is_official": false
                }
            ]
        }"#;
        let resp: SearchResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.count, 2);
        assert_eq!(resp.results.len(), 2);
        assert!(resp.results[0].is_official);
        assert!(!resp.results[1].is_official);
        // pullable_ref is not part of the Hub payload; it is populated by the
        // client after parsing.
        assert_eq!(resp.results[0].pullable_ref, "");
    }

    #[test]
    fn official_hits_resolve_into_library_namespace() {
        let official = SearchResult {
            repo_name: "python".into(),
            pullable_ref: String::new(),
            short_description: String::new(),
            star_count: 0,
            pull_count: 0,
            is_official: true,
            is_automated: false,
        };
        assert_eq!(official.compute_pullable_ref(), "docker.io/library/python");

        let community = SearchResult {
            repo_name: "circleci/python".into(),
            ..official
        };
        assert_eq!(
            community.compute_pullable_ref(),
            "docker.io/circleci/python"
        );
    }

    #[test]
    fn normalizes_tag_repository_paths() {
        assert_eq!(normalize_repo("python"), "library/python");
        assert_eq!(normalize_repo("circleci/python"), "circleci/python");
        assert_eq!(normalize_repo("docker.io/library/python"), "library/python");
        assert_eq!(
            normalize_repo("registry-1.docker.io/ubuntu/nginx"),
            "ubuntu/nginx"
        );
    }

    #[test]
    fn parses_tags_response() {
        let json = r#"{
            "count": 1,
            "results": [
                {
                    "name": "3.12-slim",
                    "full_size": 19813339,
                    "tag_last_pushed": "2026-08-13T20:30:12.571419088Z",
                    "images": [
                        {
                            "architecture": "amd64",
                            "os": "linux",
                            "digest": "sha256:c1196d36d526c4202ec8a89b7f148e6d36eca5b06525fd030a3be44731a3fe4e",
                            "size": 19813339
                        }
                    ]
                }
            ]
        }"#;
        let resp: TagsResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.count, 1);
        assert_eq!(resp.results[0].name, "3.12-slim");
        assert_eq!(resp.results[0].images[0].architecture, "amd64");
        assert_eq!(resp.results[0].full_size, Some(19813339),);
    }
}
