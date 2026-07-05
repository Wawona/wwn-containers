//! `wwn-oci` CLI: a thin front-end over the library for pulling and inspecting
//! OCI images. This is the universal, fully App-Store-compliant surface (image
//! management only - no container execution).

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use wwn_oci::registry::Credentials;
use wwn_oci::{pull, PullOptions, TargetPlatform};

#[derive(Parser)]
#[command(name = "wwn-oci", version, about = "Universal OCI image management for Wawona")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Pull an image, verify all digests, store blobs, and unpack a rootfs.
    Pull {
        /// Image reference, e.g. `alpine:3.20` or `ghcr.io/org/app@sha256:...`.
        reference: String,
        /// Directory to store blobs + rootfs under.
        #[arg(short, long, default_value = "wwn-oci-image")]
        dest: PathBuf,
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
    /// Parse a reference and print its resolved components.
    Resolve {
        reference: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("wwn-oci: error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), wwn_oci::OciError> {
    match cli.command {
        Command::Resolve { reference } => {
            let r = wwn_oci::reference::Reference::parse(&reference)?;
            println!("registry:   {}", r.registry);
            println!("repository: {}", r.repository);
            println!("tag:        {}", r.tag.as_deref().unwrap_or("-"));
            println!("digest:     {}", r.digest.as_deref().unwrap_or("-"));
            println!("base_url:   {}", r.base_url());
            Ok(())
        }
        Command::Pull { reference, dest, os, arch, no_unpack, username, password } => {
            let platform = TargetPlatform {
                arch: arch.unwrap_or_else(|| TargetPlatform::linux_host().arch),
                os,
                variant: None,
            };
            let opts = PullOptions {
                platform,
                credentials: Credentials { username, password, bearer: None },
                unpack_rootfs: !no_unpack,
            };
            let img = pull(&reference, &dest, &opts)?;
            println!("pulled {}", img.reference);
            println!("  manifest: {}", img.manifest_digest);
            println!("  config:   {}", img.config_digest);
            println!("  layers:   {}", img.layer_digests.len());
            for (i, d) in img.layer_digests.iter().enumerate() {
                println!("    [{i}] {d}");
            }
            println!("  store:    {}", img.store_root.display());
            if let Some(rootfs) = &img.rootfs {
                println!("  rootfs:   {}", rootfs.display());
            }
            if let Some(entrypoint) = &img.config.config.entrypoint {
                println!("  entrypoint: {entrypoint:?}");
            }
            if let Some(cmd) = &img.config.config.cmd {
                println!("  cmd:        {cmd:?}");
            }
            Ok(())
        }
    }
}
