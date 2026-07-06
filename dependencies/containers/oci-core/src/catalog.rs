//! Named-image catalog over the shared CAS store, so `images`/`rmi`/`inspect`
//! have a local notion of "what is pulled". Layout:
//!
//!   <root>/store/blobs/...          shared content-addressable blobs
//!   <root>/rootfs/<manifest-hex>/   unpacked rootfs per image manifest
//!   <root>/images/<ref-hash>.json   one catalog entry per canonical reference
//!
//! The default root honors WWN_OCI_ROOT, then XDG_DATA_HOME, then
//! ~/.local/share/wwn-oci — writable app-container paths on every Wawona target.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::digest::Digest;
use crate::error::OciError;
use crate::reference::Reference;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageEntry {
    /// Reference as the user gave it (display).
    pub reference: String,
    /// Canonical `registry/repo:tag` (or `@digest`) identity used for lookups.
    pub canonical: String,
    pub manifest_digest: String,
    pub config_digest: String,
    pub layer_digests: Vec<String>,
    /// Unix seconds at pull time.
    pub pulled_at_unix: u64,
    /// Unpacked rootfs directory, if the pull unpacked one.
    pub rootfs: Option<PathBuf>,
}

/// Default catalog/store root shared by all wwn-containers frontends.
pub fn default_root() -> PathBuf {
    if let Ok(root) = std::env::var("WWN_OCI_ROOT") {
        if !root.is_empty() {
            return PathBuf::from(root);
        }
    }
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            return Path::new(&xdg).join("wwn-oci");
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    Path::new(&home).join(".local").join("share").join("wwn-oci")
}

/// Canonical identity for catalog lookups: normalizes Docker Hub defaults so
/// `alpine`, `library/alpine:latest` and `docker.io/library/alpine` collide.
pub fn canonicalize(reference: &str) -> Result<String, OciError> {
    let r = Reference::parse(reference)?;
    Ok(match (&r.tag, &r.digest) {
        (_, Some(d)) => format!("{}/{}@{}", r.registry, r.repository, d),
        (Some(t), None) => format!("{}/{}:{}", r.registry, r.repository, t),
        (None, None) => format!("{}/{}:latest", r.registry, r.repository),
    })
}

fn entry_path(root: &Path, canonical: &str) -> PathBuf {
    let d = Digest::sha256_of(canonical.as_bytes());
    let (_, hex) = d.path_parts();
    root.join("images").join(format!("{}.json", &hex[..24]))
}

pub fn save(root: &Path, entry: &ImageEntry) -> Result<(), OciError> {
    let path = entry_path(root, &entry.canonical);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, serde_json::to_vec_pretty(entry)?)?;
    Ok(())
}

pub fn find(root: &Path, reference: &str) -> Result<Option<ImageEntry>, OciError> {
    let canonical = canonicalize(reference)?;
    let path = entry_path(root, &canonical);
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_slice(&fs::read(path)?)?))
}

pub fn list(root: &Path) -> Result<Vec<ImageEntry>, OciError> {
    let dir = root.join("images");
    let mut out = Vec::new();
    let rd = match fs::read_dir(&dir) {
        Ok(rd) => rd,
        Err(_) => return Ok(out), // no catalog yet == no images
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.extension().map(|x| x == "json").unwrap_or(false) {
            if let Ok(bytes) = fs::read(&p) {
                if let Ok(entry) = serde_json::from_slice::<ImageEntry>(&bytes) {
                    out.push(entry);
                }
            }
        }
    }
    out.sort_by(|a, b| a.canonical.cmp(&b.canonical));
    Ok(out)
}

/// Remove an image: catalog entry + its unpacked rootfs. Blobs stay in the
/// shared CAS (they may back other tags); a GC pass can reclaim them later.
pub fn remove(root: &Path, reference: &str) -> Result<Option<ImageEntry>, OciError> {
    let canonical = canonicalize(reference)?;
    let path = entry_path(root, &canonical);
    if !path.is_file() {
        return Ok(None);
    }
    let entry: ImageEntry = serde_json::from_slice(&fs::read(&path)?)?;
    if let Some(rootfs) = &entry.rootfs {
        // Only delete rootfs dirs we own (under <root>/rootfs/).
        if rootfs.starts_with(root.join("rootfs")) && rootfs.is_dir() {
            fs::remove_dir_all(rootfs)?;
        }
    }
    fs::remove_file(&path)?;
    Ok(Some(entry))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_docker_hub_defaults() {
        assert_eq!(
            canonicalize("alpine").unwrap(),
            canonicalize("docker.io/library/alpine:latest").unwrap()
        );
        assert_eq!(
            canonicalize("alpine:3.20").unwrap(),
            canonicalize("library/alpine:3.20").unwrap()
        );
        assert_ne!(
            canonicalize("alpine:3.20").unwrap(),
            canonicalize("alpine:3.21").unwrap()
        );
    }

    #[test]
    fn save_list_find_remove_roundtrip() {
        let root = std::env::temp_dir().join(format!("wwn-oci-catalog-{}", std::process::id()));
        let entry = ImageEntry {
            reference: "alpine:3.20".into(),
            canonical: canonicalize("alpine:3.20").unwrap(),
            manifest_digest: "sha256:abc".into(),
            config_digest: "sha256:def".into(),
            layer_digests: vec!["sha256:l1".into()],
            pulled_at_unix: 0,
            rootfs: None,
        };
        save(&root, &entry).unwrap();
        assert_eq!(list(&root).unwrap().len(), 1);
        assert!(find(&root, "docker.io/library/alpine:3.20").unwrap().is_some());
        assert!(remove(&root, "alpine:3.20").unwrap().is_some());
        assert!(list(&root).unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }
}
