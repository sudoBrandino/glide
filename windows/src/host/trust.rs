//! Host-side trust state (docs/PROTOCOL.md §2.3–§2.4), UI-free: the host identity file, host.json
//! (paired viewers, port), the pairing window with its single pairing slot, and the two-party
//! confirmation. Mirrors `mac/Sources/GlideCore/Pairing.swift`.

use crate::handshake::fingerprint;
use crate::identity::Identity;
use crate::util::{hex, unhex};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const CONFIG_FILE: &str = "host.json";
/// DPAPI-protected host key (Windows).
pub const IDENTITY_FILE_DPAPI: &str = "host-identity.dpapi";
/// Plain hex host key, mode 0600 (other OSes: tests and `--test-mode` only).
pub const IDENTITY_FILE_PLAIN: &str = "host-identity.key";
/// DPAPI extra entropy for the host key (distinct from the viewer's).
pub const IDENTITY_ENTROPY: &[u8] = b"glide windows host identity key v2";

/// How long "Pair New Mac…" / `--pair` keeps the pairing window open.
pub const PAIRING_WINDOW: Duration = Duration::from_secs(120);
/// How long one pairing may wait for both confirmations (then AuthResult 4).
pub const CONFIRM_TIMEOUT: Duration = Duration::from_secs(60);

/// `%APPDATA%\Glide` (or `GLIDE_CONFIG_DIR`). Elsewhere `$HOME/.config/glide`.
pub fn config_dir() -> Option<PathBuf> {
    if let Some(d) = std::env::var_os("GLIDE_CONFIG_DIR").filter(|d| !d.is_empty()) {
        return Some(PathBuf::from(d));
    }
    if cfg!(windows) {
        std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join("Glide"))
    } else {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config").join("glide"))
    }
}

/// ISO 8601 UTC with seconds, e.g. `2026-11-15T22:00:00Z`.
pub fn iso8601(t: SystemTime) -> String {
    let secs = t.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil_from_days (H. Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem / 60) % 60, rem % 60)
}

/// Display name for a viewer: control characters removed, trimmed, at most 40 characters.
pub fn display_name(raw: &str) -> String {
    let clean: String = raw.chars().filter(|c| !c.is_control()).collect();
    let clean = clean.trim();
    let s = if clean.is_empty() { "unnamed viewer" } else { clean };
    if s.chars().count() > 40 {
        s.chars().take(39).collect::<String>() + "…"
    } else {
        s.to_string()
    }
}

/// One viewer allowed to connect: host.json `"pairedViewers": [...]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedViewer {
    pub name: String,
    /// X25519 static public key, 64 hex chars.
    pub key: String,
    /// When it was paired (ISO 8601 UTC).
    pub paired: String,
}

impl PairedViewer {
    pub fn key_bytes(&self) -> Option<[u8; 32]> {
        let k = self.key.trim();
        if k.len() != 64 || !k.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        unhex(k).try_into().ok()
    }
    pub fn fingerprint(&self) -> String {
        self.key_bytes().map(|k| fingerprint(&k)).unwrap_or_else(|| "invalid key".into())
    }
}

/// `%APPDATA%\Glide\host.json`. Unknown fields are kept when the file is rewritten.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostConfig {
    #[serde(default)]
    pub paired_viewers: Vec<PairedViewer>,
    /// TCP port to listen on (default 7421).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// Address to bind (default all interfaces, `0.0.0.0` + `[::]`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<String>,
    /// Name sent in ServerHello (default: the computer name).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl HostConfig {
    pub fn parse(text: &str) -> Result<HostConfig, String> {
        serde_json::from_str(text).map_err(|e| e.to_string())
    }

    /// Missing file = defaults; an unreadable or invalid file is an error (never overwritten).
    pub fn load(path: &Path) -> Result<HostConfig, String> {
        match std::fs::read_to_string(path) {
            Ok(t) => HostConfig::parse(&t).map_err(|e| format!("{}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(HostConfig::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    /// Atomic write (temp file + rename).
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(d) = path.parent() {
            std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())? + "\n";
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn is_paired(&self, key: &[u8; 32]) -> bool {
        self.paired_viewers.iter().any(|v| v.key_bytes().as_ref() == Some(key))
    }

    /// Adds or refreshes (same key → new name and date) a viewer.
    pub fn add(&mut self, name: &str, key: &[u8; 32], at: SystemTime) {
        self.paired_viewers.retain(|v| v.key_bytes().as_ref() != Some(key));
        self.paired_viewers.push(PairedViewer { name: display_name(name), key: hex(key), paired: iso8601(at) });
    }

    /// Removes viewers whose name (case-insensitive) or key (hex, case-insensitive) is `what`.
    /// Returns the removed entries.
    pub fn remove(&mut self, what: &str) -> Vec<PairedViewer> {
        let w = what.trim();
        let hit = |v: &PairedViewer| v.key.eq_ignore_ascii_case(w) || v.name.to_lowercase() == w.to_lowercase();
        let removed: Vec<PairedViewer> = self.paired_viewers.iter().filter(|v| hit(v)).cloned().collect();
        self.paired_viewers.retain(|v| !hit(v));
        removed
    }
}

/// The paired-viewer list, re-read from host.json on every query so `glide-host --unpair` from
/// another console takes effect for the next connection (and ends a running session, see the
/// session loop). `path` None = in memory (tests, `--test-mode` without a config folder).
pub struct TrustStore {
    path: Option<PathBuf>,
    mem: Mutex<HostConfig>,
}

impl TrustStore {
    pub fn new(path: Option<PathBuf>, initial: HostConfig) -> TrustStore {
        TrustStore { path, mem: Mutex::new(initial) }
    }

    fn current(&self) -> HostConfig {
        let mut g = self.mem.lock().unwrap();
        if let Some(p) = &self.path {
            match HostConfig::load(p) {
                Ok(c) => *g = c,
                Err(e) => crate::host::log(&format!("trust: keeping the last good config: {e}")),
            }
        }
        g.clone()
    }

    pub fn is_paired(&self, key: &[u8; 32]) -> bool {
        self.current().is_paired(key)
    }

    pub fn list(&self) -> Vec<PairedViewer> {
        self.current().paired_viewers
    }

    /// Pins a viewer (and saves host.json).
    pub fn add(&self, name: &str, key: &[u8; 32]) -> Result<(), String> {
        let mut c = self.current();
        c.add(name, key, SystemTime::now());
        if let Some(p) = &self.path {
            c.save(p)?;
        }
        *self.mem.lock().unwrap() = c;
        Ok(())
    }
}

impl TrustStore {
    /// Unpairs viewers by name or key (and saves host.json); returns the removed entries.
    pub fn remove(&self, what: &str) -> Result<Vec<PairedViewer>, String> {
        let mut c = self.current();
        let removed = c.remove(what);
        if !removed.is_empty() {
            if let Some(p) = &self.path {
                c.save(p)?;
            }
            *self.mem.lock().unwrap() = c;
        }
        Ok(removed)
    }
}

/// The two confirmations a pairing needs: the PC user (dialog) and the viewer (PairConfirm).
/// Either "no" ends it; both "yes" pairs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PairingVote {
    pub local: Option<bool>,
    pub viewer: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoteOutcome {
    Pending,
    Paired,
    DeclinedHere,
    DeclinedByViewer,
}

impl PairingVote {
    pub fn outcome(&self) -> VoteOutcome {
        match (self.local, self.viewer) {
            (Some(false), _) => VoteOutcome::DeclinedHere,
            (_, Some(false)) => VoteOutcome::DeclinedByViewer,
            (Some(true), Some(true)) => VoteOutcome::Paired,
            _ => VoteOutcome::Pending,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Claim {
    Granted,
    Closed,
    Busy,
}

/// The pairing window ("Pair New Mac…" / `--pair`, 2 minutes) and its single pairing slot.
#[derive(Default)]
pub struct PairingWindow {
    inner: Mutex<WindowState>,
}

#[derive(Default)]
struct WindowState {
    until: Option<Instant>,
    holder: Option<u64>,
}

impl PairingWindow {
    pub fn open(&self, now: Instant, duration: Duration) {
        self.inner.lock().unwrap().until = Some(now + duration);
    }
    pub fn close(&self) {
        self.inner.lock().unwrap().until = None;
    }
    pub fn is_open(&self, now: Instant) -> bool {
        self.remaining(now).is_some()
    }
    pub fn remaining(&self, now: Instant) -> Option<Duration> {
        let g = self.inner.lock().unwrap();
        g.until.filter(|u| now < *u).map(|u| u - now)
    }
    /// Connection `id` asks to pair.
    pub fn claim(&self, id: u64, now: Instant) -> Claim {
        let mut g = self.inner.lock().unwrap();
        match g.until {
            Some(u) if now < u => {}
            _ => return Claim::Closed,
        }
        if g.holder.is_some_and(|h| h != id) {
            return Claim::Busy;
        }
        g.holder = Some(id);
        Claim::Granted
    }
    /// Connection `id` finished pairing. Success closes the window (one viewer per opening); a
    /// failure leaves it open for another try.
    pub fn release(&self, id: u64, paired: bool) {
        let mut g = self.inner.lock().unwrap();
        if g.holder != Some(id) {
            return;
        }
        g.holder = None;
        if paired {
            g.until = None;
        }
    }
}

// ---------------------------------------------------------------- identity

pub fn identity_path(dir: &Path) -> PathBuf {
    dir.join(if cfg!(windows) { IDENTITY_FILE_DPAPI } else { IDENTITY_FILE_PLAIN })
}

#[cfg(windows)]
fn seal(secret: &[u8; 32]) -> Result<Vec<u8>, String> {
    crate::win::dpapi::protect(secret, IDENTITY_ENTROPY, "Glide host identity")
}
#[cfg(windows)]
fn unseal(blob: &[u8]) -> Result<Vec<u8>, String> {
    crate::win::dpapi::unprotect(blob, IDENTITY_ENTROPY)
}
#[cfg(not(windows))]
fn seal(secret: &[u8; 32]) -> Result<Vec<u8>, String> {
    Ok((hex(secret) + "\n").into_bytes())
}
#[cfg(not(windows))]
fn unseal(blob: &[u8]) -> Result<Vec<u8>, String> {
    let s = std::str::from_utf8(blob).map_err(|e| e.to_string())?.trim();
    if s.len() != 64 || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("not a 64-hex-digit key".into());
    }
    Ok(unhex(s))
}

/// Load the host key from `dir`, creating it on first start. An existing file that can't be read
/// or decrypted is fatal: never silently replaced (every paired Mac would see a changed key).
/// Returns (identity, created).
pub fn load_or_create_identity(dir: &Path) -> Result<(Identity, bool), String> {
    let path = identity_path(dir);
    match std::fs::read(&path) {
        Ok(blob) => {
            let raw = unseal(&blob).map_err(|e| format!("cannot read {}: {e} (delete it to make this PC a new, unpaired host)", path.display()))?;
            let b: [u8; 32] = raw.try_into().map_err(|_| format!("{}: wrong key length", path.display()))?;
            Ok((Identity::from_bytes(b), false))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            let id = Identity::generate();
            let blob = seal(&id.secret().to_bytes())?;
            let tmp = path.with_extension("tmp");
            write_private(&tmp, &blob)?;
            std::fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))?;
            Ok((id, true))
        }
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

fn write_private(path: &Path, data: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path).map_err(|e| e.to_string())?;
        f.write_all(data).map_err(|e| e.to_string())
    }
    #[cfg(not(unix))]
    std::fs::write(path, data).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("glide-host-{tag}-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn iso8601_known_dates() {
        assert_eq!(iso8601(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(UNIX_EPOCH + Duration::from_secs(951_782_400)), "2000-02-29T00:00:00Z");
        assert_eq!(iso8601(UNIX_EPOCH + Duration::from_secs(1_794_780_000)), "2026-11-15T22:00:00Z");
    }

    #[test]
    fn display_names() {
        assert_eq!(display_name("  MacBook\u{7}  "), "MacBook");
        assert_eq!(display_name("\n"), "unnamed viewer");
        let long = "x".repeat(50);
        assert_eq!(display_name(&long).chars().count(), 40);
        assert!(display_name(&long).ends_with('…'));
    }

    #[test]
    fn config_roundtrip_keeps_unknown_fields() {
        let text = r#"{"pairedViewers":[{"name":"Mac","key":"0101010101010101010101010101010101010101010101010101010101010101","paired":"2026-11-15T22:00:00Z"}],"port":7500,"future":{"a":1}}"#;
        let mut c = HostConfig::parse(text).unwrap();
        assert_eq!(c.port, Some(7500));
        assert!(c.is_paired(&[1; 32]));
        assert!(!c.is_paired(&[2; 32]));
        c.add("Other\u{0}", &[2; 32], UNIX_EPOCH);
        c.add("Mac renamed", &[1; 32], UNIX_EPOCH);
        assert_eq!(c.paired_viewers.len(), 2);
        assert_eq!(c.paired_viewers[1].name, "Mac renamed");
        assert_eq!(c.paired_viewers[0].name, "Other");
        let back = HostConfig::parse(&serde_json::to_string(&c).unwrap()).unwrap();
        assert_eq!(back, c);
        assert_eq!(back.extra["future"]["a"], 1);
        // remove by name (case-insensitive) and by key
        let mut d = back.clone();
        assert_eq!(d.remove("other").len(), 1);
        assert_eq!(d.remove(&"01".repeat(32).to_uppercase()).len(), 1);
        assert!(d.paired_viewers.is_empty());
        assert!(d.remove("nobody").is_empty());
        // an invalid key never matches
        let bad = PairedViewer { name: "x".into(), key: "zz".into(), paired: String::new() };
        assert_eq!(bad.key_bytes(), None);
        assert_eq!(bad.fingerprint(), "invalid key");
        assert!(HostConfig::parse("{").is_err());
        assert_eq!(HostConfig::parse("{}").unwrap(), HostConfig::default());
    }

    #[test]
    fn trust_store_persists_and_rereads() {
        let dir = tmpdir("trust");
        let path = dir.join(CONFIG_FILE);
        let t = TrustStore::new(Some(path.clone()), HostConfig::default());
        assert!(!t.is_paired(&[3; 32]));
        t.add("Mac", &[3; 32]).unwrap();
        assert!(t.is_paired(&[3; 32]));
        t.add("Other", &[4; 32]).unwrap();
        assert_eq!(t.remove("other").unwrap().len(), 1);
        assert!(!t.is_paired(&[4; 32]));
        // another process unpairs: the next query sees it
        let mut c = HostConfig::load(&path).unwrap();
        c.remove("mac");
        c.save(&path).unwrap();
        assert!(!t.is_paired(&[3; 32]));
        // a corrupt file is not overwritten by a query
        std::fs::write(&path, "{broken").unwrap();
        assert!(HostConfig::load(&path).is_err());
        assert!(!t.is_paired(&[3; 32]));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{broken");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn vote_outcomes() {
        let v = |l, r| PairingVote { local: l, viewer: r }.outcome();
        assert_eq!(v(None, None), VoteOutcome::Pending);
        assert_eq!(v(Some(true), None), VoteOutcome::Pending);
        assert_eq!(v(None, Some(true)), VoteOutcome::Pending);
        assert_eq!(v(Some(true), Some(true)), VoteOutcome::Paired);
        assert_eq!(v(Some(false), Some(true)), VoteOutcome::DeclinedHere);
        assert_eq!(v(None, Some(false)), VoteOutcome::DeclinedByViewer);
        assert_eq!(v(Some(false), Some(false)), VoteOutcome::DeclinedHere);
    }

    #[test]
    fn pairing_window_slot() {
        let w = PairingWindow::default();
        let t0 = Instant::now();
        assert_eq!(w.claim(1, t0), Claim::Closed);
        w.open(t0, PAIRING_WINDOW);
        assert!(w.is_open(t0));
        assert_eq!(w.claim(1, t0), Claim::Granted);
        assert_eq!(w.claim(1, t0), Claim::Granted, "same connection again");
        assert_eq!(w.claim(2, t0), Claim::Busy);
        w.release(2, true); // not the holder: no effect
        assert_eq!(w.claim(2, t0), Claim::Busy);
        w.release(1, false); // failed: stays open
        assert_eq!(w.claim(2, t0), Claim::Granted);
        w.release(2, true); // success closes it
        assert!(!w.is_open(t0));
        w.open(t0, Duration::from_secs(1));
        assert!(!w.is_open(t0 + Duration::from_secs(2)));
        assert_eq!(w.claim(3, t0 + Duration::from_secs(2)), Claim::Closed);
        w.close();
        assert_eq!(w.remaining(t0), None);
    }

    #[test]
    fn identity_created_once_and_corrupt_is_fatal() {
        let dir = tmpdir("id");
        let (a, created) = load_or_create_identity(&dir).unwrap();
        assert!(created);
        let (b, created) = load_or_create_identity(&dir).unwrap();
        assert!(!created);
        assert_eq!(a.public(), b.public());
        std::fs::write(identity_path(&dir), b"garbage").unwrap();
        assert!(load_or_create_identity(&dir).is_err());
        assert_eq!(std::fs::read(identity_path(&dir)).unwrap(), b"garbage", "never replaced");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
