//! Error type for the OCI core.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum OciError {
    #[error("invalid image reference: {0}")]
    Reference(String),

    #[error("invalid digest: {0}")]
    Digest(String),

    #[error("digest mismatch: expected {expected}, got {actual}")]
    DigestMismatch { expected: String, actual: String },

    #[error("registry error ({status}): {message}")]
    Registry { status: u16, message: String },

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("unsupported media type: {0}")]
    UnsupportedMediaType(String),

    #[error("no manifest matched platform {os}/{arch}")]
    NoMatchingPlatform { os: String, arch: String },

    #[error("malformed manifest: {0}")]
    Manifest(String),

    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Json(#[from] serde_json::Error),

    #[error("http transport: {0}")]
    Transport(String),
}
