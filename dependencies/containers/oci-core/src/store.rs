//! Content-addressable blob store. Layout mirrors OCI image-layout blobs:
//!   <root>/blobs/<algo>/<hex>
//! Writes are atomic (temp file + rename) and digest-verified before commit.

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::digest::{copy_verifying, Digest};
use crate::error::OciError;

pub struct ContentStore {
    root: PathBuf,
}

impl ContentStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, OciError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("blobs"))?;
        Ok(ContentStore { root })
    }

    pub fn blob_path(&self, digest: &Digest) -> PathBuf {
        let (algo, hex) = digest.path_parts();
        self.root.join("blobs").join(algo).join(hex)
    }

    pub fn has(&self, digest: &Digest) -> bool {
        self.blob_path(digest).is_file()
    }

    /// Stream `reader` into the store, verifying it matches `expected`. Returns
    /// the number of bytes written. A no-op (fast path) if already present.
    pub fn write_verified(
        &self,
        expected: &Digest,
        reader: impl Read,
    ) -> Result<u64, OciError> {
        if self.has(expected) {
            // Drain so callers using a single connection stay in sync.
            let mut sink = io::sink();
            let mut r = reader;
            io::copy(&mut r, &mut sink)?;
            return Ok(self.blob_len(expected)?);
        }

        let dest = self.blob_path(expected);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }

        let tmp = dest.with_extension("tmp-download");
        let (actual, written) = {
            let mut f = File::create(&tmp)?;
            let (d, n) = copy_verifying(reader, &mut f)?;
            f.flush()?;
            (d, n)
        };

        if &actual != expected {
            let _ = fs::remove_file(&tmp);
            return Err(OciError::DigestMismatch {
                expected: expected.to_string(),
                actual: actual.to_string(),
            });
        }

        fs::rename(&tmp, &dest)?;
        Ok(written)
    }

    pub fn read(&self, digest: &Digest) -> Result<File, OciError> {
        Ok(File::open(self.blob_path(digest))?)
    }

    pub fn read_bytes(&self, digest: &Digest) -> Result<Vec<u8>, OciError> {
        let mut buf = Vec::new();
        self.read(digest)?.read_to_end(&mut buf)?;
        Ok(buf)
    }

    fn blob_len(&self, digest: &Digest) -> Result<u64, OciError> {
        Ok(fs::metadata(self.blob_path(digest))?.len())
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_verifies() {
        let dir = std::env::temp_dir().join(format!("wwn-oci-store-{}", std::process::id()));
        let store = ContentStore::open(&dir).unwrap();
        let data = b"hello wawona";
        let d = Digest::sha256_of(data);
        assert!(!store.has(&d));
        store.write_verified(&d, &data[..]).unwrap();
        assert!(store.has(&d));
        assert_eq!(store.read_bytes(&d).unwrap(), data);

        // Wrong expected digest must be rejected.
        let wrong = Digest::sha256_of(b"other");
        let err = store.write_verified(&wrong, &b"mismatch"[..]).unwrap_err();
        matches!(err, OciError::DigestMismatch { .. });
        let _ = fs::remove_dir_all(&dir);
    }
}
