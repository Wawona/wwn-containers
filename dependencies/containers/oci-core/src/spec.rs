//! OCI / Docker image-spec types and media-type constants.

use serde::{Deserialize, Serialize};

pub mod media_type {
    // OCI
    pub const OCI_INDEX: &str = "application/vnd.oci.image.index.v1+json";
    pub const OCI_MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";
    pub const OCI_CONFIG: &str = "application/vnd.oci.image.config.v1+json";
    pub const OCI_LAYER_TAR: &str = "application/vnd.oci.image.layer.v1.tar";
    pub const OCI_LAYER_GZIP: &str = "application/vnd.oci.image.layer.v1.tar+gzip";
    pub const OCI_LAYER_ZSTD: &str = "application/vnd.oci.image.layer.v1.tar+zstd";
    // Docker v2 schema 2
    pub const DOCKER_MANIFEST_LIST: &str = "application/vnd.docker.distribution.manifest.list.v2+json";
    pub const DOCKER_MANIFEST: &str = "application/vnd.docker.distribution.manifest.v2+json";
    pub const DOCKER_CONFIG: &str = "application/vnd.docker.container.image.v1+json";
    pub const DOCKER_LAYER_GZIP: &str = "application/vnd.docker.image.rootfs.diff.tar.gzip";

    /// The `Accept` header we send so the registry may return either an index or
    /// a single manifest, in OCI or Docker flavor.
    pub fn accept_all() -> String {
        [OCI_INDEX, OCI_MANIFEST, DOCKER_MANIFEST_LIST, DOCKER_MANIFEST].join(", ")
    }

    pub fn is_index(mt: &str) -> bool {
        mt == OCI_INDEX || mt == DOCKER_MANIFEST_LIST
    }

    pub fn is_manifest(mt: &str) -> bool {
        mt == OCI_MANIFEST || mt == DOCKER_MANIFEST
    }

    pub fn is_gzip_layer(mt: &str) -> bool {
        mt == OCI_LAYER_GZIP || mt == DOCKER_LAYER_GZIP
    }

    pub fn is_zstd_layer(mt: &str) -> bool {
        mt == OCI_LAYER_ZSTD
    }

    pub fn is_plain_tar_layer(mt: &str) -> bool {
        mt == OCI_LAYER_TAR
    }
}

/// A content descriptor pointing at a blob by digest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Descriptor {
    #[serde(rename = "mediaType")]
    pub media_type: String,
    pub digest: String,
    pub size: i64,
    #[serde(default)]
    pub platform: Option<Platform>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub urls: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Platform {
    pub architecture: String,
    pub os: String,
    #[serde(default, rename = "os.version", skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    #[serde(default)]
    pub variant: Option<String>,
}

/// Image index / manifest list (multi-arch).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageIndex {
    #[serde(rename = "schemaVersion")]
    pub schema_version: i64,
    #[serde(default)]
    pub manifests: Vec<Descriptor>,
}

/// Single-arch image manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageManifest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: i64,
    #[serde(default, rename = "mediaType")]
    pub media_type: Option<String>,
    pub config: Descriptor,
    #[serde(default)]
    pub layers: Vec<Descriptor>,
}

/// Image config (partial: the pieces a runtime cares about).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageConfig {
    #[serde(default)]
    pub architecture: String,
    #[serde(default)]
    pub os: String,
    #[serde(default)]
    pub config: RuntimeConfig,
    #[serde(default)]
    pub rootfs: RootFs,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RuntimeConfig {
    #[serde(default, rename = "Env")]
    pub env: Vec<String>,
    #[serde(default, rename = "Entrypoint")]
    pub entrypoint: Option<Vec<String>>,
    #[serde(default, rename = "Cmd")]
    pub cmd: Option<Vec<String>>,
    #[serde(default, rename = "WorkingDir")]
    pub working_dir: Option<String>,
    #[serde(default, rename = "User")]
    pub user: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RootFs {
    #[serde(default, rename = "type")]
    pub fs_type: String,
    #[serde(default, rename = "diff_ids")]
    pub diff_ids: Vec<String>,
}
