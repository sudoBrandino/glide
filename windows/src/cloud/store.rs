//! Enrollment state (docs/ENTERPRISE.md §11.3): `cloud-host.dpapi` / `cloud-viewer.dpapi` next to
//! the app's config, DPAPI-protected for the current user (like the identity key). Content:
//! `{"cloud_url", "org_id", "device_id", "device_token", "enrolled_at"}`, plus `user_token` and
//! `user_token_expires` on the viewer. This app also keeps the org name, the signed-in user and the
//! last settings it received there (display, and the LAN-mode decision at startup before the hub
//! has answered; settings from the cloud always replace them).

use super::api::{Settings, User};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const HOST_FILE: &str = "cloud-host.dpapi";
pub const VIEWER_FILE: &str = "cloud-viewer.dpapi";
/// DPAPI extra entropy for enrollment files.
pub const ENTROPY: &[u8] = b"glide cloud enrollment v1";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct Enrollment {
    pub cloud_url: String,
    pub org_id: String,
    pub device_id: String,
    pub device_token: String,
    pub enrolled_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_token: Option<String>,
    /// RFC 3339 UTC.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_token_expires: Option<String>,
    // Local extensions (display / startup decisions only).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub org_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<User>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settings: Option<Settings>,
}

impl Enrollment {
    /// A user token that hasn't expired at `now` (seconds since the Unix epoch).
    pub fn live_user_token(&self, now: i64) -> Option<&str> {
        let t = self.user_token.as_deref().filter(|t| !t.is_empty())?;
        let exp = self.user_token_expires.as_deref().and_then(crate::connections::parse_rfc3339)?;
        (now + 30 < exp).then_some(t)
    }

    pub fn clear_user(&mut self) {
        self.user_token = None;
        self.user_token_expires = None;
        self.user = None;
    }

    /// The device token looks like one (`gd_` + 43 base64url characters, §6.1).
    pub fn plausible(&self) -> bool {
        !self.device_id.is_empty() && self.device_token.starts_with("gd_") && self.device_token.len() >= 10
    }
}

/// Encrypts the file at rest (DPAPI on Windows; identity in tests).
pub trait Seal: Send + Sync {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String>;
    fn open(&self, blob: &[u8]) -> Result<Vec<u8>, String>;
}

/// DPAPI, current user (Windows).
#[cfg(windows)]
pub struct Dpapi;

#[cfg(windows)]
impl Seal for Dpapi {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String> {
        crate::win::dpapi::protect(plain, ENTROPY, "Glide Cloud enrollment")
    }
    fn open(&self, blob: &[u8]) -> Result<Vec<u8>, String> {
        crate::win::dpapi::unprotect(blob, ENTROPY)
    }
}

/// No encryption: tests, and non-Windows builds (file mode 0600).
pub struct Plain;

impl Seal for Plain {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String> {
        Ok(plain.to_vec())
    }
    fn open(&self, blob: &[u8]) -> Result<Vec<u8>, String> {
        Ok(blob.to_vec())
    }
}

/// The platform's sealing (DPAPI on Windows).
pub fn platform_seal() -> Arc<dyn Seal> {
    #[cfg(windows)]
    {
        Arc::new(Dpapi)
    }
    #[cfg(not(windows))]
    {
        Arc::new(Plain)
    }
}

#[derive(Clone)]
pub struct Store {
    pub path: PathBuf,
    seal: Arc<dyn Seal>,
}

impl Store {
    pub fn new(dir: &Path, file: &str, seal: Arc<dyn Seal>) -> Store {
        Store { path: dir.join(file), seal }
    }

    /// Ok(None) = not enrolled. Err = the file exists but can't be read (kept, not replaced).
    pub fn load(&self) -> Result<Option<Enrollment>, String> {
        let blob = match std::fs::read(&self.path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("cannot read {}: {e}", self.path.display())),
        };
        let plain = self.seal.open(&blob).map_err(|e| format!("cannot decrypt {}: {e}", self.path.display()))?;
        let e: Enrollment = serde_json::from_slice(&plain).map_err(|e| format!("{} is damaged: {e}", self.path.display()))?;
        Ok(Some(e))
    }

    /// Atomic write (temp file + rename).
    pub fn save(&self, e: &Enrollment) -> Result<(), String> {
        let plain = serde_json::to_vec(e).map_err(|e| e.to_string())?;
        let blob = self.seal.seal(&plain)?;
        if let Some(d) = self.path.parent() {
            std::fs::create_dir_all(d).map_err(|e| format!("cannot create {}: {e}", d.display()))?;
        }
        let tmp = self.path.with_extension("tmp");
        write_private(&tmp, &blob).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| format!("cannot replace {}: {e}", self.path.display()))
    }

    /// Delete the enrollment (revoked, or re-enrolling elsewhere).
    pub fn wipe(&self) -> Result<(), String> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("cannot delete {}: {e}", self.path.display())),
        }
    }
}

fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
        f.write_all(data)
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, data)
    }
}

#[cfg(test)]
pub(crate) fn temp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("glide-cloud-{tag}-{}-{}", std::process::id(), super::backoff::random_unit().to_bits()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A reversible stand-in for DPAPI, to prove the file isn't plaintext.
    struct Xor;
    impl Seal for Xor {
        fn seal(&self, p: &[u8]) -> Result<Vec<u8>, String> {
            Ok(p.iter().map(|b| b ^ 0x5a).collect())
        }
        fn open(&self, b: &[u8]) -> Result<Vec<u8>, String> {
            Ok(b.iter().map(|b| b ^ 0x5a).collect())
        }
    }

    #[test]
    fn save_load_wipe() {
        let dir = temp_dir("store");
        let s = Store::new(&dir, VIEWER_FILE, Arc::new(Xor));
        assert_eq!(s.load(), Ok(None));
        let e = Enrollment {
            cloud_url: "https://c.example.com".into(),
            org_id: "org_1".into(),
            device_id: "dev_1".into(),
            device_token: "gd_0123456789012345678901234567890123456789012".into(),
            enrolled_at: "2026-11-25T10:00:00Z".into(),
            user_token: Some("gu_x".into()),
            user_token_expires: Some("2026-11-25T22:00:00Z".into()),
            ..Default::default()
        };
        s.save(&e).unwrap();
        let raw = std::fs::read(&s.path).unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("gd_"), "sealed at rest");
        assert_eq!(s.load().unwrap(), Some(e.clone()));
        // The fields §11.3 names, by name.
        let v: serde_json::Value = serde_json::from_slice(&Xor.open(&raw).unwrap()).unwrap();
        for k in ["cloud_url", "org_id", "device_id", "device_token", "enrolled_at", "user_token", "user_token_expires"] {
            assert!(v.get(k).is_some(), "{k}");
        }
        s.wipe().unwrap();
        assert_eq!(s.load(), Ok(None));
        s.wipe().unwrap();
        // A file that doesn't decode is an error, not "not enrolled".
        std::fs::write(&s.path, b"\x00garbage").unwrap();
        assert!(s.load().is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn user_token_lifetime() {
        let mut e = Enrollment { user_token: Some("gu_x".into()), user_token_expires: Some("2026-11-25T22:00:00Z".into()), ..Default::default() };
        let exp = crate::connections::parse_rfc3339("2026-11-25T22:00:00Z").unwrap();
        assert_eq!(e.live_user_token(exp - 3600), Some("gu_x"));
        assert_eq!(e.live_user_token(exp - 10), None, "about to expire");
        assert_eq!(e.live_user_token(exp + 1), None);
        e.user_token_expires = None;
        assert_eq!(e.live_user_token(0), None, "no expiry known: not trusted");
        e.clear_user();
        assert!(e.user_token.is_none());
    }
}
