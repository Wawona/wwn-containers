//! Content digests (OCI uses `sha256:<hex>`), plus streaming verification.

use std::fmt;
use std::io::{self, Read, Write};

use sha2::{Digest as _, Sha256};

use crate::error::OciError;

/// A parsed content digest, e.g. `sha256:abcd...`.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Digest {
    pub algorithm: String,
    pub hex: String,
}

impl Digest {
    /// Parse `algo:hex`. Only `sha256` (and `sha512`) are accepted; the hex must
    /// be well-formed and the right length for the algorithm.
    pub fn parse(s: &str) -> Result<Self, OciError> {
        let (algorithm, hex) = s
            .split_once(':')
            .ok_or_else(|| OciError::Digest(format!("missing ':' in digest {s:?}")))?;
        let expected_len = match algorithm {
            "sha256" => 64,
            "sha512" => 128,
            other => return Err(OciError::Digest(format!("unsupported digest algorithm {other:?}"))),
        };
        if hex.len() != expected_len || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(OciError::Digest(format!("malformed {algorithm} digest {s:?}")));
        }
        Ok(Digest {
            algorithm: algorithm.to_string(),
            hex: hex.to_ascii_lowercase(),
        })
    }

    /// Compute the sha256 digest of a byte slice.
    pub fn sha256_of(bytes: &[u8]) -> Digest {
        let mut h = Sha256::new();
        h.update(bytes);
        Digest {
            algorithm: "sha256".to_string(),
            hex: hex::encode(h.finalize()),
        }
    }

    /// Filesystem-safe encoding used by the CAS layout: `<algo>/<hex>`.
    pub fn path_parts(&self) -> (&str, &str) {
        (&self.algorithm, &self.hex)
    }
}

impl fmt::Display for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.algorithm, self.hex)
    }
}

impl fmt::Debug for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self}")
    }
}

/// A `Read`/`Write` wrapper that computes a sha256 as bytes flow through, so a
/// blob can be verified while it is streamed to disk without a second pass.
pub struct Sha256Reader<R> {
    inner: R,
    hasher: Sha256,
    read: u64,
}

impl<R: Read> Sha256Reader<R> {
    pub fn new(inner: R) -> Self {
        Sha256Reader { inner, hasher: Sha256::new(), read: 0 }
    }

    /// Finalize and return `(digest, bytes_read)`.
    pub fn finalize(self) -> (Digest, u64) {
        (
            Digest { algorithm: "sha256".to_string(), hex: hex::encode(self.hasher.finalize()) },
            self.read,
        )
    }
}

impl<R: Read> Read for Sha256Reader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        self.read += n as u64;
        Ok(n)
    }
}

/// Copy `reader` into `writer`, returning the digest of everything copied.
pub fn copy_verifying<R: Read, W: Write>(reader: R, writer: &mut W) -> io::Result<(Digest, u64)> {
    let mut hashed = Sha256Reader::new(reader);
    io::copy(&mut hashed, writer)?;
    Ok(hashed.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_rejects() {
        let d = Digest::parse("sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855").unwrap();
        assert_eq!(d.algorithm, "sha256");
        assert!(Digest::parse("sha256:zz").is_err());
        assert!(Digest::parse("md5:abcd").is_err());
        assert!(Digest::parse("nocolon").is_err());
    }

    #[test]
    fn digests_empty() {
        let d = Digest::sha256_of(b"");
        assert_eq!(d.hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }
}
