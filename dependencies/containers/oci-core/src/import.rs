//! Import an image from disk into the local catalog, auto-detecting the
//! source format:
//!
//!   * **OCI layout directory** — a directory containing `oci-layout` +
//!     `index.json` + `blobs/…` (skopeo `oci:`, and what the macOS run side
//!     loads via `ImageStore.load(from:)`).
//!   * **OCI-archive tar** — the same layout inside a tar (or tar.gz).
//!   * **docker-archive tar** — `docker save` output: `manifest.json` + config
//!     JSON + layer tars (or tar.gz).
//!
//! Every ingested blob is digest-verified against the source manifest (or
//! computed when the docker-archive format carries no digests), stored in the
//! content-addressed store, unpacked to a per-manifest rootfs, cataloged, and
//! an OCI layout directory is emitted alongside for the macOS execution
//! backend (`wwn-containerd --image-archive`).

use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use flate2::read::GzDecoder;
use serde::Deserialize;
use tar::Archive;

use crate::catalog;
use crate::digest::Digest;
use crate::error::OciError;
use crate::spec::{media_type, Descriptor, ImageIndex, ImageManifest, Platform};
use crate::store::ContentStore;
use crate::unpack;

/// The OCI image-spec annotation carrying the pullable reference.
pub const REF_NAME_ANNOTATION: &str = "org.opencontainers.image.ref.name";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SourceFormat {
    OciLayoutDir,
    OciArchiveTar,
    DockerArchive,
}

/// Options controlling an import.
pub struct ImportOptions {
    /// Reference to catalog the image under. When absent, the image's own
    /// metadata wins (docker-archive `RepoTags`, OCI `ref.name` annotation),
    /// then `local/<basename>:latest`.
    pub reference: Option<String>,
    /// If set, layers are applied into `<image_root>/rootfs/<manifest-hex>`.
    pub unpack_rootfs: bool,
}

impl Default for ImportOptions {
    fn default() -> Self {
        ImportOptions {
            reference: None,
            unpack_rootfs: true,
        }
    }
}

/// The result of a successful import.
pub struct ImportedImage {
    /// Reference the image was cataloged under (canonical form).
    pub reference: String,
    pub manifest_digest: Digest,
    pub config_digest: Digest,
    pub layer_digests: Vec<Digest>,
    /// Extracted rootfs, if `unpack_rootfs` was requested.
    pub rootfs: Option<PathBuf>,
    /// Generated OCI layout directory for `wwn-containerd --image-archive`.
    pub oci_layout: PathBuf,
}

/// Import `path` into the catalog/store rooted at `image_root`.
pub fn import_image(
    path: &Path,
    image_root: &Path,
    opts: &ImportOptions,
) -> Result<ImportedImage, OciError> {
    let store = ContentStore::open(image_root.join("store"))?;
    match detect_format(path)? {
        SourceFormat::DockerArchive => import_docker_archive(path, image_root, &store, opts),
        SourceFormat::OciLayoutDir => import_oci_layout(path, image_root, &store, opts),
        SourceFormat::OciArchiveTar => {
            let tmp = temp_extract_dir()?;
            let result = {
                extract_tar(path, &tmp)?;
                import_oci_layout(&tmp, image_root, &store, opts)
            };
            let _ = fs::remove_dir_all(&tmp);
            result
        }
    }
}

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

fn detect_format(path: &Path) -> Result<SourceFormat, OciError> {
    if path.is_dir() {
        if path.join("oci-layout").is_file() {
            return Ok(SourceFormat::OciLayoutDir);
        }
        return Err(OciError::Manifest(format!(
            "'{}' is a directory but not an OCI layout (missing oci-layout file)",
            path.display()
        )));
    }
    if !path.is_file() {
        return Err(OciError::Manifest(format!(
            "'{}' is neither a file nor an OCI layout directory",
            path.display()
        )));
    }

    let mut has_manifest_json = false;
    let mut has_index_json = false;
    let mut has_oci_layout = false;
    let mut archive = open_tar(path)?;
    for entry in archive.entries()? {
        let entry = entry?;
        let name = entry.path()?.to_string_lossy().into_owned();
        let plain = name.trim_start_matches("./");
        match plain {
            "manifest.json" => has_manifest_json = true,
            "index.json" => has_index_json = true,
            "oci-layout" => has_oci_layout = true,
            _ => {}
        }
    }

    if has_index_json && has_oci_layout {
        Ok(SourceFormat::OciArchiveTar)
    } else if has_manifest_json {
        Ok(SourceFormat::DockerArchive)
    } else {
        Err(OciError::Manifest(format!(
            "'{}' is not a recognized image archive (expected docker-archive manifest.json, or OCI layout index.json + oci-layout)",
            path.display()
        )))
    }
}

/// Open `path` as a tar stream, transparently decompressing gzip.
fn open_tar(path: &Path) -> Result<Archive<Box<dyn Read>>, OciError> {
    let mut file = File::open(path)?;
    let mut magic = [0u8; 2];
    let n = file.read(&mut magic)?;
    drop(file);
    let file = File::open(path)?;
    if n == 2 && magic == [0x1f, 0x8b] {
        Ok(Archive::new(Box::new(GzDecoder::new(file)) as Box<dyn Read>))
    } else {
        Ok(Archive::new(Box::new(file) as Box<dyn Read>))
    }
}

fn is_gzip(bytes: &[u8]) -> bool {
    bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
}

fn read_tar_entry(archive: &mut Archive<Box<dyn Read>>, name: &str) -> Result<Vec<u8>, OciError> {
    for entry in archive.entries()? {
        let mut entry = entry?;
        let entry_name = entry.path()?.to_string_lossy().into_owned();
        let plain = entry_name.trim_start_matches("./");
        if plain == name {
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf)?;
            return Ok(buf);
        }
    }
    Err(OciError::Manifest(format!(
        "entry '{}' not found in archive",
        name
    )))
}

fn temp_extract_dir() -> Result<PathBuf, OciError> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("wwn-oci-import-{}-{}", std::process::id(), nanos));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn extract_tar(path: &Path, dest: &Path) -> Result<(), OciError> {
    let mut archive = open_tar(path)?;
    archive.set_preserve_permissions(true);
    archive.unpack(dest)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// docker-archive (docker save)
// ---------------------------------------------------------------------------

/// One element of docker-archive's `manifest.json` array.
#[derive(Deserialize)]
struct DockerArchiveEntry {
    #[serde(rename = "Config")]
    config: String,
    #[serde(rename = "RepoTags", default)]
    repo_tags: Option<Vec<String>>,
    #[serde(rename = "Layers", default)]
    layers: Vec<String>,
}

fn import_docker_archive(
    path: &Path,
    image_root: &Path,
    store: &ContentStore,
    opts: &ImportOptions,
) -> Result<ImportedImage, OciError> {
    let manifest_bytes = {
        let mut archive = open_tar(path)?;
        read_tar_entry(&mut archive, "manifest.json")?
    };
    let entries: Vec<DockerArchiveEntry> = serde_json::from_slice(&manifest_bytes)?;
    let entry = entries
        .first()
        .ok_or_else(|| OciError::Manifest("docker-archive manifest.json is empty".into()))?;

    // 1. Config blob.
    let config_bytes = {
        let mut archive = open_tar(path)?;
        read_tar_entry(&mut archive, &entry.config)?
    };
    let config_digest = Digest::sha256_of(&config_bytes);
    store.write_verified(&config_digest, &config_bytes[..])?;

    // 2. Layers (no digests in docker-archive: compute + verify on write).
    let mut layer_digests = Vec::with_capacity(entry.layers.len());
    let mut layer_specs = Vec::with_capacity(entry.layers.len());
    for layer_name in &entry.layers {
        let bytes = {
            let mut archive = open_tar(path)?;
            read_tar_entry(&mut archive, layer_name)?
        };
        let d = Digest::sha256_of(&bytes);
        store.write_verified(&d, &bytes[..])?;
        let media = if is_gzip(&bytes) {
            media_type::DOCKER_LAYER_GZIP
        } else {
            media_type::OCI_LAYER_TAR
        };
        layer_specs.push((media, d.clone(), bytes.len() as i64));
        layer_digests.push(d);
    }

    // 3. Synthesize an OCI manifest (docker-archive carries no manifest blob).
    let manifest = ImageManifest {
        schema_version: 2,
        media_type: Some(media_type::OCI_MANIFEST.to_string()),
        config: Descriptor {
            media_type: media_type::DOCKER_CONFIG.to_string(),
            digest: config_digest.to_string(),
            size: config_bytes.len() as i64,
            platform: None,
            urls: vec![],
            annotations: None,
        },
        layers: layer_specs
            .iter()
            .map(|(media, d, size)| Descriptor {
                media_type: media.to_string(),
                digest: d.to_string(),
                size: *size,
                platform: None,
                urls: vec![],
                annotations: None,
            })
            .collect(),
    };
    let manifest_json = serde_json::to_vec(&manifest)?;
    let manifest_digest = Digest::sha256_of(&manifest_json);
    store.write_verified(&manifest_digest, &manifest_json[..])?;

    let reference = resolve_reference(
        opts.reference.as_deref(),
        entry
            .repo_tags
            .as_deref()
            .and_then(|t| t.first().map(String::as_str)),
        path,
    )?;

    finish_import(
        image_root,
        store,
        &manifest,
        reference,
        manifest_digest,
        config_digest,
        layer_digests,
        opts,
    )
}

// ---------------------------------------------------------------------------
// OCI layout directory
// ---------------------------------------------------------------------------

fn import_oci_layout(
    dir: &Path,
    image_root: &Path,
    store: &ContentStore,
    opts: &ImportOptions,
) -> Result<ImportedImage, OciError> {
    let index_bytes = fs::read(dir.join("index.json"))?;
    let index: ImageIndex = serde_json::from_slice(&index_bytes)?;

    // Prefer a linux/arm64 image, then linux/amd64, then the first manifest.
    let chosen = select_descriptor(&index)?;
    let manifest_digest = Digest::parse(&chosen.digest)?;
    let manifest_bytes = fs::read(
        dir.join("blobs")
            .join(manifest_digest.path_parts().0)
            .join(manifest_digest.path_parts().1),
    )?;
    let manifest: ImageManifest = serde_json::from_slice(&manifest_bytes)?;
    store.write_verified(&manifest_digest, &manifest_bytes[..])?;

    let config_digest = Digest::parse(&manifest.config.digest)?;
    copy_layout_blob(dir, store, &config_digest)?;

    let mut layer_digests = Vec::with_capacity(manifest.layers.len());
    for layer in &manifest.layers {
        let d = Digest::parse(&layer.digest)?;
        copy_layout_blob(dir, store, &d)?;
        layer_digests.push(d);
    }

    let reference = resolve_reference(
        opts.reference.as_deref(),
        chosen
            .annotations
            .as_ref()
            .and_then(|a| a.get(REF_NAME_ANNOTATION).map(String::as_str)),
        dir,
    )?;

    finish_import(
        image_root,
        store,
        &manifest,
        reference,
        manifest_digest,
        config_digest,
        layer_digests,
        opts,
    )
}

fn select_descriptor<'a>(index: &'a ImageIndex) -> Result<&'a Descriptor, OciError> {
    let manifests: Vec<&Descriptor> = index
        .manifests
        .iter()
        .filter(|d| media_type::is_manifest(&d.media_type))
        .collect();
    if manifests.is_empty() {
        return Err(OciError::NoMatchingPlatform {
            os: "linux".into(),
            arch: "any".into(),
        });
    }
    let pick = |os: &str, arch: &str| {
        manifests.iter().copied().find(|d| {
            d.platform
                .as_ref()
                .map(|p| p.os == os && p.architecture == arch)
                .unwrap_or(false)
        })
    };
    Ok(pick("linux", "arm64")
        .or_else(|| pick("linux", "amd64"))
        .unwrap_or(manifests[0]))
}

fn copy_layout_blob(dir: &Path, store: &ContentStore, digest: &Digest) -> Result<(), OciError> {
    if store.has(digest) {
        return Ok(());
    }
    let (algo, hex) = digest.path_parts();
    let src = dir.join("blobs").join(algo).join(hex);
    let file = File::open(&src)?;
    store.write_verified(digest, file)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Shared tail: unpack, catalog-worthy layout dir, reference resolution
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn finish_import(
    image_root: &Path,
    store: &ContentStore,
    manifest: &ImageManifest,
    reference: String,
    manifest_digest: Digest,
    config_digest: Digest,
    layer_digests: Vec<Digest>,
    opts: &ImportOptions,
) -> Result<ImportedImage, OciError> {
    let canonical = catalog::canonicalize(&reference)?;

    // 1. Optional rootfs unpack (mirrors `pull`: per-manifest dir + marker).
    let rootfs = if opts.unpack_rootfs {
        let dir = image_root.join("rootfs").join(&manifest_digest.hex);
        if !dir.join(".unpacked").is_file() {
            if dir.is_dir() {
                fs::remove_dir_all(&dir)?; // partial unpack: restart
            }
            for (layer, d) in manifest.layers.iter().zip(&layer_digests) {
                let blob = store.read(d)?;
                unpack::apply_layer(&layer.media_type, blob, &dir)?;
            }
            fs::write(dir.join(".unpacked"), b"")?;
        }
        Some(dir)
    } else {
        None
    };

    // 2. OCI layout directory for the macOS execution backend.
    let layout = image_root.join("oci-layout").join(&manifest_digest.hex);
    if !layout.join("oci-layout").is_file() {
        write_oci_layout(
            store,
            &layout,
            &manifest_digest,
            manifest,
            &config_digest,
            &canonical,
        )?;
    }

    Ok(ImportedImage {
        reference: canonical,
        manifest_digest,
        config_digest,
        layer_digests,
        rootfs,
        oci_layout: layout,
    })
}

fn write_oci_layout(
    store: &ContentStore,
    layout: &Path,
    manifest_digest: &Digest,
    manifest: &ImageManifest,
    config_digest: &Digest,
    canonical: &str,
) -> Result<(), OciError> {
    let blobs = layout.join("blobs").join("sha256");
    fs::create_dir_all(&blobs)?;

    // oci-layout marker.
    fs::write(
        layout.join("oci-layout"),
        br#"{"imageLayoutVersion": "1.0.0"}"#.to_vec(),
    )?;

    // Hard-link the CAS blobs into the layout (same filesystem; copy fallback).
    let link = |digest: &Digest| -> Result<(), OciError> {
        let src = store.blob_path(digest);
        let dst = blobs.join(&digest.hex);
        if dst.exists() {
            return Ok(());
        }
        match fs::hard_link(&src, &dst) {
            Ok(()) => Ok(()),
            Err(_) => {
                fs::copy(&src, &dst)?;
                Ok(())
            }
        }
    };
    link(config_digest)?;
    for layer in &manifest.layers {
        link(&Digest::parse(&layer.digest)?)?;
    }
    let manifest_bytes = store.read_bytes(manifest_digest)?;
    link(manifest_digest)?;

    // index.json with the pullable reference annotation.
    use std::collections::BTreeMap;
    let mut annotations = BTreeMap::new();
    annotations.insert(REF_NAME_ANNOTATION.to_string(), canonical.to_string());
    let index = ImageIndex {
        schema_version: 2,
        manifests: vec![Descriptor {
            media_type: media_type::OCI_MANIFEST.to_string(),
            digest: manifest_digest.to_string(),
            size: manifest_bytes.len() as i64,
            platform: Some(Platform {
                architecture: "arm64".into(),
                os: "linux".into(),
                os_version: None,
                variant: Some("v8".into()),
            }),
            urls: vec![],
            annotations: Some(annotations),
        }],
    };
    fs::write(layout.join("index.json"), serde_json::to_vec(&index)?)?;
    Ok(())
}

fn resolve_reference(
    override_ref: Option<&str>,
    metadata_ref: Option<&str>,
    path: &Path,
) -> Result<String, OciError> {
    if let Some(r) = override_ref.filter(|s| !s.trim().is_empty()) {
        return Ok(r.trim().to_string());
    }
    if let Some(r) = metadata_ref.filter(|s| !s.trim().is_empty()) {
        // Hub-style references may come through as `docker.io/…`; keep as-is.
        return Ok(r.trim().to_string());
    }
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("imported");
    Ok(format!("local/{stem}:latest"))
}
