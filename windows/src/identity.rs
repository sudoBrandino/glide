//! The viewer's long-term identity: an X25519 static key pair (docs/PROTOCOL.md §2.3).
//!
//! Stored next to config.json: on Windows `identity.dpapi`, the private key encrypted with DPAPI
//! (`CryptProtectData`, current user, extra entropy) so only this Windows account on this PC can
//! use it; elsewhere (tests, the headless bench on macOS/Linux) `identity.key`, hex, mode 0600.
//! Created on first use. Deleting it makes the viewer a new, unpaired device.

use crate::handshake::fingerprint;
use crate::noise::public_key;
use rand_core::OsRng;
use std::path::{Path, PathBuf};
use x25519_dalek::StaticSecret;

pub const IDENTITY_FILE_DPAPI: &str = "identity.dpapi";
pub const IDENTITY_FILE_PLAIN: &str = "identity.key";

#[derive(Clone)]
pub struct Identity {
    secret: [u8; 32],
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Identity({})", self.fingerprint())
    }
}

impl Identity {
    pub fn generate() -> Identity {
        Identity { secret: StaticSecret::random_from_rng(OsRng).to_bytes() }
    }
    pub fn from_bytes(b: [u8; 32]) -> Identity {
        Identity { secret: b }
    }
    pub fn secret(&self) -> StaticSecret {
        StaticSecret::from(self.secret)
    }
    pub fn public(&self) -> [u8; 32] {
        public_key(&self.secret())
    }
    pub fn fingerprint(&self) -> String {
        fingerprint(&self.public())
    }
}

/// Where the identity lives in `dir` on this platform.
pub fn identity_path(dir: &Path) -> PathBuf {
    if cfg!(windows) {
        dir.join(IDENTITY_FILE_DPAPI)
    } else {
        dir.join(IDENTITY_FILE_PLAIN)
    }
}

#[cfg(windows)]
fn seal(secret: &[u8; 32]) -> Result<Vec<u8>, String> {
    crate::win::dpapi::protect(secret, crate::win::dpapi::IDENTITY_ENTROPY, "Glide viewer identity")
}
#[cfg(windows)]
fn unseal(blob: &[u8]) -> Result<Vec<u8>, String> {
    crate::win::dpapi::unprotect(blob, crate::win::dpapi::IDENTITY_ENTROPY)
}
#[cfg(not(windows))]
fn seal(secret: &[u8; 32]) -> Result<Vec<u8>, String> {
    Ok((crate::util::hex(secret) + "\n").into_bytes())
}
#[cfg(not(windows))]
fn unseal(blob: &[u8]) -> Result<Vec<u8>, String> {
    let s = std::str::from_utf8(blob).map_err(|e| e.to_string())?.trim();
    if s.len() != 64 || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("not a 64-hex-digit key".into());
    }
    Ok(crate::util::unhex(s))
}

/// Write the identity atomically (temp file + rename), 0600 on Unix.
fn store(path: &Path, id: &Identity) -> Result<(), String> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
    }
    let blob = seal(&id.secret)?;
    let tmp = path.with_extension("tmp");
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp).map_err(|e| e.to_string())?;
        f.write_all(&blob).map_err(|e| e.to_string())?;
    }
    #[cfg(not(unix))]
    std::fs::write(&tmp, &blob).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

#[derive(Debug, PartialEq, Eq)]
pub enum Loaded {
    Existing,
    Created,
    /// No config folder: a throwaway identity (pairing will not survive a restart).
    Ephemeral,
}

/// Load the identity from `dir`, creating it on first use. An existing file that can't be
/// read/decrypted is an error (never silently replaced: that would unpair the viewer).
pub fn load_or_create(dir: Option<&Path>) -> Result<(Identity, Loaded), String> {
    let Some(dir) = dir else { return Ok((Identity::generate(), Loaded::Ephemeral)) };
    let path = identity_path(dir);
    match std::fs::read(&path) {
        Ok(blob) => {
            let raw = unseal(&blob).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            let b: [u8; 32] = raw.try_into().map_err(|_| format!("{}: wrong key length", path.display()))?;
            Ok((Identity::from_bytes(b), Loaded::Existing))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let id = Identity::generate();
            store(&path, &id)?;
            Ok((id, Loaded::Created))
        }
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_then_reload_same_key() {
        let dir = std::env::temp_dir().join(format!("glide-id-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (a, how) = load_or_create(Some(&dir)).unwrap();
        assert_eq!(how, Loaded::Created);
        let (b, how) = load_or_create(Some(&dir)).unwrap();
        assert_eq!(how, Loaded::Existing);
        assert_eq!(a.public(), b.public());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(identity_path(&dir)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // a corrupt file is an error, not silently replaced
        std::fs::write(identity_path(&dir), b"garbage").unwrap();
        assert!(load_or_create(Some(&dir)).is_err());
        assert_eq!(load_or_create(None).unwrap().1, Loaded::Ephemeral);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(a.fingerprint().len(), 19);
    }
}
