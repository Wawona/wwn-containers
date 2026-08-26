//! Apply image layers onto a rootfs directory, honoring OCI whiteouts.
//!
//! Layers are tar streams (optionally gzip-compressed). Applied in order, each
//! overlays the previous. Whiteout markers:
//!   `.wh.<name>`        delete `<name>` from the same directory
//!   `.wh..wh..opq`      opaque dir: delete everything already in this directory

use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use flate2::read::GzDecoder;
use tar::{Archive, EntryType};

use crate::error::OciError;
use crate::spec::media_type;

const WHITEOUT_PREFIX: &str = ".wh.";
const WHITEOUT_OPAQUE: &str = ".wh..wh..opq";

/// Apply a single layer blob to `rootfs`, selecting the decompressor from the
/// layer's media type.
pub fn apply_layer(
    layer_media_type: &str,
    reader: impl Read,
    rootfs: &Path,
) -> Result<(), OciError> {
    if media_type::is_gzip_layer(layer_media_type) {
        apply_tar(GzDecoder::new(reader), rootfs)
    } else if media_type::is_plain_tar_layer(layer_media_type) {
        apply_tar(reader, rootfs)
    } else if media_type::is_zstd_layer(layer_media_type) {
        Err(OciError::UnsupportedMediaType(format!(
            "{layer_media_type} (zstd layers not yet supported)"
        )))
    } else {
        Err(OciError::UnsupportedMediaType(layer_media_type.to_string()))
    }
}

fn apply_tar(reader: impl Read, rootfs: &Path) -> Result<(), OciError> {
    fs::create_dir_all(rootfs)?;
    let mut archive = Archive::new(reader);
    archive.set_preserve_permissions(true);
    archive.set_preserve_mtime(true);
    archive.set_unpack_xattrs(true);

    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();

        let file_name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let parent = path.parent().unwrap_or_else(|| Path::new(""));

        // Whiteouts are metadata, not files to extract.
        if file_name == WHITEOUT_OPAQUE {
            let dir = safe_join(rootfs, parent)?;
            remove_dir_contents(&dir)?;
            continue;
        }
        if let Some(target) = file_name.strip_prefix(WHITEOUT_PREFIX) {
            let victim = safe_join(rootfs, &parent.join(target))?;
            remove_path(&victim)?;
            continue;
        }

        let dest = safe_join(rootfs, &path)?;
        if let Some(p) = dest.parent() {
            ensure_writable_ancestors(p)?;
            fs::create_dir_all(p)?;
        }

        // For non-directory entries, clear whatever is already there so a later
        // layer cleanly replaces a file/symlink from an earlier one.
        if entry.header().entry_type() != EntryType::Directory && symlink_or_exists(&dest) {
            remove_path(&dest)?;
        }

        entry.unpack(&dest)?;
    }
    Ok(())
}

/// Join `rel` under `base`. OCI/Docker layer tars often use absolute paths
/// (`/etc/passwd`); strip a single leading root component. Reject `..`
/// traversal so a malicious layer cannot escape the rootfs.
fn safe_join(base: &Path, rel: &Path) -> Result<PathBuf, OciError> {
    let mut out = base.to_path_buf();
    let mut components = rel.components().peekable();
    if matches!(components.peek(), Some(Component::RootDir)) {
        components.next();
    }
    for comp in components {
        match comp {
            Component::Normal(c) => out.push(c),
            Component::CurDir => {}
            Component::RootDir | Component::Prefix(_) => {
                return Err(OciError::Manifest(format!(
                    "absolute path in layer entry: {}",
                    rel.display()
                )))
            }
            Component::ParentDir => {
                return Err(OciError::Manifest(format!(
                    "path traversal in layer entry: {}",
                    rel.display()
                )))
            }
        }
    }
    Ok(out)
}

fn symlink_or_exists(p: &Path) -> bool {
    p.symlink_metadata().is_ok()
}

/// Layer tars may mark store paths read-only; later entries in the same or a
/// following layer still need to create children underneath.
fn ensure_writable_ancestors(path: &Path) -> Result<(), OciError> {
    let mut cursor = Some(path);
    while let Some(current) = cursor {
        if current.exists() {
            let mut perms = current.metadata()?.permissions();
            if perms.readonly() {
                perms.set_readonly(false);
                fs::set_permissions(current, perms)?;
            }
        }
        cursor = current.parent();
    }
    Ok(())
}

fn remove_path(p: &Path) -> Result<(), OciError> {
    match p.symlink_metadata() {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(p)?,
        Ok(_) => fs::remove_file(p)?,
        Err(_) => {}
    }
    Ok(())
}

fn remove_dir_contents(dir: &Path) -> Result<(), OciError> {
    if !dir.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)? {
        remove_path(&entry?.path())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_traversal() {
        let base = Path::new("/tmp/rootfs");
        assert!(safe_join(base, Path::new("../etc/passwd")).is_err());
        assert_eq!(
            safe_join(base, Path::new("/etc/passwd")).unwrap(),
            Path::new("/tmp/rootfs/etc/passwd")
        );
        assert_eq!(
            safe_join(base, Path::new("a/./b")).unwrap(),
            Path::new("/tmp/rootfs/a/b")
        );
    }
}
