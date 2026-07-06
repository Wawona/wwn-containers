//! `wwn-oci` CLI: universal OCI image management (pull/list/remove/inspect).
//! This is the fully App-Store-compliant surface - no container execution -
//! shared by every Wawona target. The `container` CLI fronts it for image
//! commands and delegates execution to the per-target backend.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};

use wwn_oci::registry::Credentials;
use wwn_oci::{catalog, pull, unpack, PullOptions, TargetPlatform};

#[derive(Parser)]
#[command(name = "wwn-oci", version, about = "Universal OCI image management for Wawona")]
struct Cli {
    /// Image store root (blobs + rootfs + catalog). Defaults to $WWN_OCI_ROOT,
    /// then $XDG_DATA_HOME/wwn-oci, then ~/.local/share/wwn-oci.
    #[arg(long, global = true)]
    root: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Pull an image, verify all digests, store blobs, unpack a rootfs, and
    /// record it in the local image catalog.
    Pull {
        /// Image reference, e.g. `alpine:3.20` or `ghcr.io/org/app@sha256:...`.
        reference: String,
        /// Target OS (default: linux).
        #[arg(long, default_value = "linux")]
        os: String,
        /// Target arch (default: host arch, e.g. arm64/amd64).
        #[arg(long)]
        arch: Option<String>,
        /// Skip unpacking the rootfs (download + store only).
        #[arg(long)]
        no_unpack: bool,
        /// Registry username (private images).
        #[arg(long, env = "WWN_OCI_USERNAME")]
        username: Option<String>,
        /// Registry password/token (private images).
        #[arg(long, env = "WWN_OCI_PASSWORD")]
        password: Option<String>,
    },
    /// List images in the local catalog.
    Images,
    /// Remove an image from the catalog (deletes its unpacked rootfs; shared
    /// blobs are kept for other tags).
    Rmi {
        reference: String,
    },
    /// Show a pulled image's manifest/config digests, layers, and rootfs path.
    Inspect {
        reference: String,
    },
    /// Parse a reference and print its resolved components.
    Resolve {
        reference: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("wwn-oci: error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<ExitCode, wwn_oci::OciError> {
    let root = cli.root.unwrap_or_else(catalog::default_root);
    match cli.command {
        Command::Resolve { reference } => {
            let r = wwn_oci::reference::Reference::parse(&reference)?;
            println!("registry:   {}", r.registry);
            println!("repository: {}", r.repository);
            println!("tag:        {}", r.tag.as_deref().unwrap_or("-"));
            println!("digest:     {}", r.digest.as_deref().unwrap_or("-"));
            println!("base_url:   {}", r.base_url());
            Ok(ExitCode::SUCCESS)
        }
        Command::Pull { reference, os, arch, no_unpack, username, password } => {
            let platform = TargetPlatform {
                arch: arch.unwrap_or_else(|| TargetPlatform::linux_host().arch),
                os,
                variant: None,
            };
            let opts = PullOptions {
                platform,
                credentials: Credentials { username, password, bearer: None },
                // Unpack is done below into a per-image dir, not pull()'s
                // shared <root>/rootfs (which would collide across images).
                unpack_rootfs: false,
            };
            let img = pull(&reference, &root, &opts)?;

            // Per-image rootfs keyed by manifest digest (content-addressed, so
            // re-pulling the same image is a fast no-op re-unpack guard).
            let rootfs = if no_unpack {
                None
            } else {
                let dir = root.join("rootfs").join(&img.manifest_digest.hex);
                if !dir.join(".unpacked").is_file() {
                    let store = wwn_oci::store::ContentStore::open(root.join("store"))?;
                    if dir.is_dir() {
                        std::fs::remove_dir_all(&dir)?; // partial unpack: restart
                    }
                    for d in &img.layer_digests {
                        let blob = store.read(d)?;
                        // Layer media types were validated during pull; gzip tar
                        // is the norm and apply_layer sniffs the rest.
                        unpack::apply_layer("application/vnd.oci.image.layer.v1.tar+gzip", blob, &dir)?;
                    }
                    std::fs::write(dir.join(".unpacked"), b"")?;
                }
                Some(dir)
            };

            let entry = catalog::ImageEntry {
                reference: reference.clone(),
                canonical: catalog::canonicalize(&reference)?,
                manifest_digest: img.manifest_digest.to_string(),
                config_digest: img.config_digest.to_string(),
                layer_digests: img.layer_digests.iter().map(|d| d.to_string()).collect(),
                pulled_at_unix: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
                rootfs: rootfs.clone(),
            };
            catalog::save(&root, &entry)?;

            println!("pulled {}", entry.canonical);
            println!("  manifest: {}", entry.manifest_digest);
            println!("  config:   {}", entry.config_digest);
            println!("  layers:   {}", entry.layer_digests.len());
            if let Some(rootfs) = &rootfs {
                println!("  rootfs:   {}", rootfs.display());
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Images => {
            let entries = catalog::list(&root)?;
            if entries.is_empty() {
                eprintln!("no images pulled (root: {})", root.display());
                return Ok(ExitCode::SUCCESS);
            }
            println!("{:<48} {:<20} {}", "IMAGE", "MANIFEST", "PULLED");
            for e in entries {
                let short = e
                    .manifest_digest
                    .strip_prefix("sha256:")
                    .unwrap_or(&e.manifest_digest);
                println!(
                    "{:<48} {:<20} {}",
                    e.canonical,
                    &short[..12.min(short.len())],
                    e.pulled_at_unix
                );
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Rmi { reference } => match catalog::remove(&root, &reference)? {
            Some(e) => {
                println!("removed {}", e.canonical);
                Ok(ExitCode::SUCCESS)
            }
            None => {
                eprintln!("wwn-oci: image not found: {reference}");
                Ok(ExitCode::FAILURE)
            }
        },
        Command::Inspect { reference } => match catalog::find(&root, &reference)? {
            Some(e) => {
                println!("{}", serde_json::to_string_pretty(&e)?);
                Ok(ExitCode::SUCCESS)
            }
            None => {
                eprintln!("wwn-oci: image not found: {reference} (pull it first)");
                Ok(ExitCode::FAILURE)
            }
        },
    }
}
