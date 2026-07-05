//! wwn-oci: universal OCI image management for Wawona.
//!
//! Pure-userspace, cross-platform building blocks (no container execution, no
//! Linux kernel required) so this crate runs on every Wawona target including
//! iOS and watchOS:
//!
//!   * [`reference`] - parse image references (Docker Hub defaults).
//!   * [`registry`]  - Registry v2 client (token auth, manifest, blobs).
//!   * [`digest`]    - `sha256:` digests + streaming verification.
//!   * [`store`]     - content-addressable blob store (OCI layout).
//!   * [`spec`]      - OCI/Docker image-spec types + media types.
//!   * [`unpack`]    - apply layers to a rootfs with whiteout handling.
//!
//! The [`pull`] entry point ties them together: resolve -> verify -> store ->
//! (optionally) unpack a rootfs.

pub mod digest;
pub mod error;
pub mod reference;
pub mod registry;
pub mod spec;
pub mod store;
pub mod unpack;

use std::path::{Path, PathBuf};

pub use error::OciError;

use digest::Digest;
use reference::Reference;
use registry::{Credentials, RegistryClient};
use spec::{media_type, ImageConfig, ImageIndex, ImageManifest};

/// Target platform to select from a multi-arch index.
#[derive(Debug, Clone)]
pub struct TargetPlatform {
    pub os: String,
    pub arch: String,
    pub variant: Option<String>,
}

impl TargetPlatform {
    /// Default to a linux guest matching the host CPU (containers are Linux).
    pub fn linux_host() -> Self {
        let arch = match std::env::consts::ARCH {
            "x86_64" => "amd64",
            "aarch64" => "arm64",
            other => other,
        };
        let variant = if arch == "arm64" { Some("v8".to_string()) } else { None };
        TargetPlatform { os: "linux".to_string(), arch: arch.to_string(), variant }
    }

    fn matches(&self, p: &spec::Platform) -> bool {
        p.os == self.os
            && p.architecture == self.arch
            && match (&self.variant, &p.variant) {
                // A missing variant on either side is treated as compatible.
                (Some(a), Some(b)) => a == b,
                _ => true,
            }
    }
}

/// The result of a successful pull.
#[derive(Debug, Clone)]
pub struct PulledImage {
    pub reference: String,
    pub manifest_digest: Digest,
    pub config_digest: Digest,
    pub layer_digests: Vec<Digest>,
    pub config: ImageConfig,
    /// Where blobs were stored (CAS root).
    pub store_root: PathBuf,
    /// Extracted rootfs, if `unpack_rootfs` was requested.
    pub rootfs: Option<PathBuf>,
}

/// Options controlling a pull.
pub struct PullOptions {
    pub platform: TargetPlatform,
    pub credentials: Credentials,
    /// If set, layers are applied into `<image_root>/rootfs`.
    pub unpack_rootfs: bool,
}

impl Default for PullOptions {
    fn default() -> Self {
        PullOptions {
            platform: TargetPlatform::linux_host(),
            credentials: Credentials::default(),
            unpack_rootfs: true,
        }
    }
}

/// Pull `reference_str` into `image_root`, verifying every blob's digest.
pub fn pull(
    reference_str: &str,
    image_root: &Path,
    opts: &PullOptions,
) -> Result<PulledImage, OciError> {
    let reference = Reference::parse(reference_str)?;
    let mut client = RegistryClient::new(opts.credentials.clone());
    let store = store::ContentStore::open(image_root.join("store"))?;

    // 1. Resolve the (possibly multi-arch) top-level document to a single
    //    image manifest for the requested platform.
    let top = client.get_manifest(&reference)?;
    let (manifest_bytes, manifest_digest) = if media_type::is_index(&top.media_type) {
        let index: ImageIndex = serde_json::from_slice(&top.bytes)?;
        let chosen = select_platform(&index, &opts.platform)?;
        let child_digest = Digest::parse(&chosen.digest)?;
        let child = client.get_manifest_by_digest(&reference, &child_digest)?;
        (child.bytes, child.digest)
    } else if media_type::is_manifest(&top.media_type) {
        (top.bytes, top.digest)
    } else {
        return Err(OciError::UnsupportedMediaType(top.media_type));
    };

    let manifest: ImageManifest = serde_json::from_slice(&manifest_bytes)?;

    // 2. Config blob.
    let config_digest = Digest::parse(&manifest.config.digest)?;
    download_blob(&mut client, &reference, &store, &config_digest)?;
    let config: ImageConfig = serde_json::from_slice(&store.read_bytes(&config_digest)?)?;

    // 3. Layers (verify + store).
    let mut layer_digests = Vec::with_capacity(manifest.layers.len());
    for layer in &manifest.layers {
        let d = Digest::parse(&layer.digest)?;
        download_blob(&mut client, &reference, &store, &d)?;
        layer_digests.push(d);
    }

    // 4. Optional rootfs unpack.
    let rootfs = if opts.unpack_rootfs {
        let root = image_root.join("rootfs");
        for (layer, d) in manifest.layers.iter().zip(&layer_digests) {
            let blob = store.read(d)?;
            unpack::apply_layer(&layer.media_type, blob, &root)?;
        }
        Some(root)
    } else {
        None
    };

    Ok(PulledImage {
        reference: reference_str.to_string(),
        manifest_digest,
        config_digest,
        layer_digests,
        config,
        store_root: store.root().to_path_buf(),
        rootfs,
    })
}

fn download_blob(
    client: &mut RegistryClient,
    reference: &Reference,
    store: &store::ContentStore,
    digest: &Digest,
) -> Result<(), OciError> {
    if store.has(digest) {
        return Ok(());
    }
    let reader = client.blob_reader(reference, digest)?;
    store.write_verified(digest, reader)?;
    Ok(())
}

fn select_platform<'a>(
    index: &'a ImageIndex,
    platform: &TargetPlatform,
) -> Result<&'a spec::Descriptor, OciError> {
    index
        .manifests
        .iter()
        // Skip attestation/unknown entries that carry no usable platform.
        .filter(|d| d.platform.as_ref().map(|p| p.os != "unknown").unwrap_or(false))
        .find(|d| d.platform.as_ref().map(|p| platform.matches(p)).unwrap_or(false))
        .or_else(|| {
            // Fall back to the first real image manifest if nothing matched.
            index.manifests.iter().find(|d| media_type::is_manifest(&d.media_type))
        })
        .ok_or_else(|| OciError::NoMatchingPlatform {
            os: platform.os.clone(),
            arch: platform.arch.clone(),
        })
}
