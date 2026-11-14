//! Persistent viewer settings: `%APPDATA%\Glide\config.json` (override the directory with
//! `GLIDE_CONFIG_DIR`). Platform independent so load/save/migration and the "what does a
//! no-argument launch do" logic are unit-tested on macOS.
//!
//! Security v2 (docs/PROTOCOL.md §1–2): `pinned_hosts` holds the host public key pinned for each
//! target after pairing. The viewer's own private key is NOT stored here: it lives
//! DPAPI-encrypted next to it (`identity.dpapi`, see `identity`). Passwords are gone: a v1
//! `password.dpapi` file is left alone (so the v1 viewer still works after a rollback) but no
//! longer read, and a plaintext `"password"` key is dropped from the file.

use crate::protocol::{Mode, DEFAULT_PORT};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const CONFIG_VERSION: u32 = 1;
pub const CONFIG_FILE: &str = "config.json";
/// v1 saved password (DPAPI). No longer read; only mentioned once in the log if present.
pub const LEGACY_PASSWORD_FILE: &str = "password.dpapi";

/// A host public key pinned by pairing (docs/PROTOCOL.md §2.3).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct PinnedHost {
    /// X25519 static public key, 64 hex chars.
    pub key: String,
    /// Host name from ServerHello at pairing time (display only).
    pub name: String,
    /// When it was paired (RFC 3339 UTC).
    pub paired: String,
}

impl PinnedHost {
    pub fn key_bytes(&self) -> Option<[u8; 32]> {
        let k = self.key.trim();
        if k.len() != 64 || !k.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        crate::util::unhex(k).try_into().ok()
    }
}

/// Remembered window state on one monitor. Position is relative to that monitor's top-left
/// (so it survives monitor re-arrangement); `mon_w`/`mon_h` record the monitor size at save time.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Default)]
#[serde(default)]
pub struct WindowState {
    /// Normal (restored) outer window rect, relative to the monitor origin, physical pixels.
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub maximized: bool,
    pub fullscreen: bool,
    pub mon_w: i32,
    pub mon_h: i32,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Config {
    pub version: u32,
    /// Port for listen (reverse-connect) mode, used when no host is configured.
    pub listen_port: u16,
    /// If set (and no CLI target is given), dial this host instead of listening.
    pub host: Option<String>,
    /// "fast" | "sharp" | "hybrid"; None = automatic (hybrid if 4:4:4 decode works).
    pub mode: Option<String>,
    /// Ctrl → Command, Win → Control, Alt → Option.
    pub ctrl_as_cmd: bool,
    /// Stats overlay (Ctrl+Alt+Shift+H).
    pub hud: bool,
    /// Connection bar always shown (menu → Pin connection bar).
    pub bar_pinned: bool,
    /// Play the Mac's audio (`--no-audio` overrides to off).
    pub audio: bool,
    /// Audio muted (Ctrl+Alt+Shift+A / tray / window menu); persists across restarts.
    pub audio_muted: bool,
    /// Clipboard sync with the host (`--no-clipboard` overrides to off).
    pub clipboard: bool,
    /// Also sync clipboard items marked secret/concealed (password managers). Off by default.
    pub clipboard_sync_secrets: bool,
    /// File transfer with the host (drag & drop onto the window, Ctrl+Alt+Shift+V; §6).
    pub file_transfer: bool,
    /// Accept files the Mac sends (menu "Send Files to Viewer…", Ctrl+Alt+Shift+V).
    pub file_receive: bool,
    /// Where received files go; None = `<Downloads>\Glide`.
    pub download_dir: Option<String>,
    /// Largest transfer (bytes) accepted or sent.
    pub file_max_total_bytes: u64,
    /// Most files per transfer.
    pub file_max_files: u32,
    /// Listen mode: only these IPs / CIDRs may connect (checked before any handshake byte).
    /// Empty = trust on first use: the first host that authenticates is pinned here.
    pub allowed_peers: Vec<String>,
    /// Host keys pinned by pairing, keyed by target (`pin_target`): "host:port" when dialing,
    /// "listen:PORT" in listen mode.
    pub pinned_hosts: BTreeMap<String, PinnedHost>,
    /// Monitor (device name, e.g. `\\.\DISPLAY1`) the window was last on.
    pub last_monitor: Option<String>,
    /// Per-monitor window state, keyed by monitor device name.
    pub windows: BTreeMap<String, WindowState>,
    /// The Mac display last chosen in the display picker, per target (`pin_target`), by stable
    /// identity (PROTOCOL.md §3.5). Absent = the host's default display.
    pub last_display: BTreeMap<String, crate::displays::DisplayIdentity>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            version: CONFIG_VERSION,
            listen_port: DEFAULT_PORT,
            host: None,
            mode: None,
            ctrl_as_cmd: true,
            hud: false,
            bar_pinned: false,
            audio: true,
            audio_muted: false,
            clipboard: true,
            clipboard_sync_secrets: false,
            file_transfer: true,
            file_receive: true,
            download_dir: None,
            file_max_total_bytes: 8 << 30,
            file_max_files: 10_000,
            allowed_peers: Vec::new(),
            pinned_hosts: BTreeMap::new(),
            last_monitor: None,
            windows: BTreeMap::new(),
            last_display: BTreeMap::new(),
        }
    }
}

pub fn mode_from_str(s: &str) -> Option<Mode> {
    match s.trim().to_ascii_lowercase().as_str() {
        "fast" => Some(Mode::Fast),
        "sharp" => Some(Mode::Sharp),
        "hybrid" => Some(Mode::Hybrid),
        _ => None,
    }
}

impl Config {
    pub fn mode(&self) -> Option<Mode> {
        self.mode.as_deref().and_then(mode_from_str)
    }
    pub fn set_mode(&mut self, m: Mode) {
        self.mode = Some(m.name().to_string());
    }
    /// The host key pinned for `target` (`pin_target`), if any and valid.
    pub fn pinned_key(&self, target: &str) -> Option<[u8; 32]> {
        self.pinned_hosts.get(target).and_then(PinnedHost::key_bytes)
    }
}

/// Pin-store key for a connection target: "host:port" (normalized, lowercase) when dialing,
/// "listen:PORT" in listen mode (whoever dials in must present that key).
pub fn pin_target(t: &TargetSpec) -> String {
    match t {
        TargetSpec::Connect(h) => crate::net::parse_addr(h.trim()).to_ascii_lowercase(),
        TargetSpec::Listen(p) => format!("listen:{p}"),
    }
}

/// RFC 3339 UTC timestamp ("2026-11-06T13:05:09Z") for `pinned_hosts[..].paired`.
pub fn rfc3339_utc(t: std::time::SystemTime) -> String {
    let secs = t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (m <= 2) as i64;
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

/// Result of loading a config file.
#[derive(Debug, Default)]
pub struct Loaded {
    pub config: Config,
    /// The file had a plaintext v1 `"password"` key (dropped; passwords are no longer used).
    pub legacy_password: bool,
    /// The on-disk file should be rewritten (migrated, or missing fields filled in).
    pub needs_save: bool,
    /// Non-fatal problem (e.g. unparsable file, which was moved aside).
    pub warning: Option<String>,
}

/// Parse + migrate config JSON text. Never fails: bad input yields defaults plus a warning.
pub fn parse(text: &str) -> Loaded {
    let mut v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v @ serde_json::Value::Object(_)) => v,
        Ok(_) => return Loaded { warning: Some("config is not a JSON object; using defaults".into()), ..Default::default() },
        Err(e) => return Loaded { warning: Some(format!("config parse error: {e}; using defaults")), ..Default::default() },
    };
    let obj = v.as_object_mut().unwrap();
    let mut out = Loaded::default();
    let version = obj.get("version").and_then(|x| x.as_u64()).unwrap_or(0);

    // --- migrations (version 0 = hand-written / pre-release files)
    if version < 1 {
        // "port" / "listen" → "listen_port"
        for legacy in ["port", "listen"] {
            if let Some(p) = obj.remove(legacy) {
                if !obj.contains_key("listen_port") {
                    if let Some(n) = p.as_u64().filter(|n| (1..=65535).contains(n)) {
                        obj.insert("listen_port".into(), n.into());
                    }
                }
            }
        }
        // "connect" → "host"
        if let Some(h) = obj.remove("connect") {
            if !obj.contains_key("host") && h.is_string() {
                obj.insert("host".into(), h);
            }
        }
        // "no_ctrl_as_cmd": true → "ctrl_as_cmd": false
        if let Some(b) = obj.remove("no_ctrl_as_cmd").and_then(|b| b.as_bool()) {
            obj.entry("ctrl_as_cmd").or_insert((!b).into());
        }
        out.needs_save = true;
    }
    // A plaintext password never stays in the file (any version); v2 doesn't use passwords.
    if obj.remove("password").is_some() {
        out.legacy_password = true;
        out.needs_save = true;
    }
    obj.insert("version".into(), CONFIG_VERSION.into());

    // Field-by-field so one bad value doesn't discard everything else.
    let d = Config::default();
    let get = |k: &str| obj.get(k).cloned();
    let mut c = d.clone();
    let mut bad = Vec::new();
    macro_rules! field {
        ($name:ident) => {
            if let Some(x) = get(stringify!($name)) {
                match serde_json::from_value(x) {
                    Ok(val) => c.$name = val,
                    Err(_) => bad.push(stringify!($name)),
                }
            } else {
                out.needs_save = true;
            }
        };
    }
    field!(listen_port);
    field!(host);
    field!(mode);
    field!(ctrl_as_cmd);
    field!(hud);
    field!(bar_pinned);
    field!(audio);
    field!(audio_muted);
    field!(clipboard);
    field!(clipboard_sync_secrets);
    field!(file_transfer);
    field!(file_receive);
    field!(download_dir);
    field!(file_max_total_bytes);
    field!(file_max_files);
    field!(allowed_peers);
    field!(pinned_hosts);
    field!(last_monitor);
    field!(windows);
    field!(last_display);
    if c.listen_port == 0 {
        c.listen_port = d.listen_port;
        bad.push("listen_port");
    }
    if c.mode.as_deref().is_some_and(|m| mode_from_str(m).is_none()) {
        c.mode = None;
        bad.push("mode");
    }
    let before = c.pinned_hosts.len();
    c.pinned_hosts.retain(|_, p| p.key_bytes().is_some());
    if c.pinned_hosts.len() != before {
        bad.push("pinned_hosts");
    }
    if c.host.as_deref().is_some_and(|h| h.trim().is_empty()) {
        c.host = None;
    }
    if c.download_dir.as_deref().is_some_and(|h| h.trim().is_empty()) {
        c.download_dir = None;
    }
    c.version = CONFIG_VERSION;
    if !bad.is_empty() {
        out.warning = Some(format!("ignored invalid config value(s): {}", bad.join(", ")));
        out.needs_save = true;
    }
    out.config = c;
    out
}

pub fn to_json(c: &Config) -> String {
    serde_json::to_string_pretty(c).expect("config serializes") + "\n"
}

/// Load `path`. Missing file → defaults with `needs_save`. An unparsable file is renamed to
/// `config.json.bad` so the user's edits aren't silently overwritten.
pub fn load(path: &Path) -> Loaded {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let l = parse(&text);
            if l.warning.as_deref().is_some_and(|w| w.contains("parse error") || w.contains("not a JSON object")) {
                let _ = std::fs::rename(path, path.with_extension("json.bad"));
                return Loaded { needs_save: true, ..l };
            }
            l
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Loaded { needs_save: true, ..Default::default() },
        Err(e) => Loaded { warning: Some(format!("cannot read {}: {e}", path.display())), ..Default::default() },
    }
}

/// Atomic save (write a temp file, then rename over the old one). Creates the directory.
pub fn save(path: &Path, c: &Config) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, to_json(c))?;
    std::fs::rename(&tmp, path)
}

/// `GLIDE_CONFIG_DIR`, else `%APPDATA%\Glide` (Windows) / `$XDG_CONFIG_HOME|~/.config/glide`.
pub fn config_dir_from(env: impl Fn(&str) -> Option<String>) -> Option<PathBuf> {
    if let Some(d) = env("GLIDE_CONFIG_DIR").filter(|s| !s.is_empty()) {
        return Some(PathBuf::from(d));
    }
    if cfg!(windows) {
        return env("APPDATA").filter(|s| !s.is_empty()).map(|a| PathBuf::from(a).join("Glide"));
    }
    if let Some(x) = env("XDG_CONFIG_HOME").filter(|s| !s.is_empty()) {
        return Some(PathBuf::from(x).join("glide"));
    }
    env("HOME").map(|h| PathBuf::from(h).join(".config").join("glide"))
}

pub fn config_dir() -> Option<PathBuf> {
    config_dir_from(|k| std::env::var(k).ok())
}

/// The live config plus where it is saved. `update` writes the file only when something changed.
#[derive(Debug, Clone, Default)]
pub struct Store {
    /// Config directory; None = not persisted (no APPDATA).
    pub dir: Option<PathBuf>,
    pub config: Config,
}

impl Store {
    /// Load from `dir` (or defaults if None), applying migrations. Returns the store and
    /// warnings/notices to print.
    pub fn open(dir: Option<PathBuf>) -> (Store, Vec<String>) {
        let mut warnings = Vec::new();
        let Some(d) = dir else { return (Store::default(), warnings) };
        let l = load(&d.join(CONFIG_FILE));
        warnings.extend(l.warning);
        if l.legacy_password {
            warnings.push("removed the plaintext v1 \"password\" from config.json (passwords are no longer used; Glide v2 pairs keys)".into());
        }
        let st = Store { dir: Some(d), config: l.config };
        if l.needs_save {
            if let Err(e) = st.save() {
                warnings.push(format!("cannot write config: {e}"));
            }
        }
        (st, warnings)
    }

    pub fn path(&self) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join(CONFIG_FILE))
    }

    pub fn save(&self) -> std::io::Result<()> {
        match self.path() {
            Some(p) => save(&p, &self.config),
            None => Ok(()),
        }
    }

    /// After a successful pairing: pin the host key for `target` (replaces an older pin).
    pub fn pin_host(&mut self, target: &str, key: &[u8; 32], host_name: &str) {
        let pin = PinnedHost { key: crate::util::hex(key), name: host_name.to_string(), paired: rfc3339_utc(std::time::SystemTime::now()) };
        self.update(|c| {
            c.pinned_hosts.insert(target.to_string(), pin);
        });
        eprintln!("pinned host key {} for {target} (config pinned_hosts)", crate::handshake::fingerprint(key));
    }

    /// Unpair: forget the host key pinned for `target`. Returns the removed pin.
    pub fn forget_host(&mut self, target: &str) -> Option<PinnedHost> {
        let mut had = None;
        self.update(|c| had = c.pinned_hosts.remove(target));
        had
    }

    /// Apply `f`; save if the config changed. Errors are reported, not fatal.
    pub fn update(&mut self, f: impl FnOnce(&mut Config)) {
        let before = self.config.clone();
        f(&mut self.config);
        if self.config != before {
            if let Err(e) = self.save() {
                eprintln!("warning: cannot save config: {e}");
            }
        }
    }
}

// ------------------------------------------------------------------ connection target

/// Where the viewer connects, after merging CLI and config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetSpec {
    Listen(u16),
    Connect(String),
}

/// CLI wins: a positional host, then `--listen [PORT]`; else the config's `host`; else listen on
/// the configured port. So `glide-client.exe` with no arguments = listen on 7420 by default.
pub fn resolve_target(cli_host: Option<&str>, cli_listen: Option<u16>, c: &Config) -> TargetSpec {
    if let Some(h) = cli_host {
        return TargetSpec::Connect(h.to_string());
    }
    if let Some(p) = cli_listen {
        return TargetSpec::Listen(p);
    }
    match c.host.as_deref().map(str::trim).filter(|h| !h.is_empty()) {
        Some(h) => TargetSpec::Connect(h.to_string()),
        None => TargetSpec::Listen(c.listen_port),
    }
}

/// Effective stream mode: CLI, then config, then auto; 4:4:4 modes need `has444`.
/// Returns (mode, note) where note explains a fallback.
pub fn resolve_mode(cli: Option<Mode>, c: &Config, has444: bool) -> (Mode, Option<String>) {
    match cli.or_else(|| c.mode()) {
        None => (if has444 { Mode::Hybrid } else { Mode::Fast }, None),
        Some(m @ (Mode::Sharp | Mode::Hybrid)) if !has444 => {
            (Mode::Fast, Some(format!("mode {} requested but this PC can't decode HEVC 4:4:4; using fast", m.name())))
        }
        Some(m) => (m, None),
    }
}

// ------------------------------------------------------------------ window placement

/// Plain rectangle (left, top, right, bottom), screen coordinates, physical pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rect {
    pub l: i32,
    pub t: i32,
    pub r: i32,
    pub b: i32,
}

impl Rect {
    pub fn w(&self) -> i32 {
        self.r - self.l
    }
    pub fn h(&self) -> i32 {
        self.b - self.t
    }
    fn intersect_area(&self, o: &Rect) -> i64 {
        let w = (self.r.min(o.r) - self.l.max(o.l)).max(0) as i64;
        let h = (self.b.min(o.b) - self.t.max(o.t)).max(0) as i64;
        w * h
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorDesc {
    pub key: String,
    pub rect: Rect,
    pub work: Rect,
}

/// The window state to restore at startup.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placement {
    pub monitor: usize,
    /// Normal outer window rect, absolute screen coordinates, guaranteed mostly on `monitor`.
    pub rect: Rect,
    pub maximized: bool,
    pub fullscreen: bool,
}

/// Pick the monitor + saved state to restore: the last-used monitor if it still exists and has
/// saved state, else the saved state of the monitor under the cursor. None = no saved state
/// (use the default: centered on the cursor monitor).
pub fn choose_placement(c: &Config, monitors: &[MonitorDesc], cursor_monitor: Option<usize>) -> Option<Placement> {
    let find = |key: &str| monitors.iter().position(|m| m.key == key);
    let pick = c
        .last_monitor
        .as_deref()
        .and_then(|k| Some((find(k)?, c.windows.get(k)?)))
        .or_else(|| {
            let i = cursor_monitor?;
            Some((i, c.windows.get(&monitors.get(i)?.key)?))
        })?;
    let (i, ws) = pick;
    let m = &monitors[i];
    Some(Placement {
        monitor: i,
        rect: fit_rect(Rect { l: m.rect.l + ws.x, t: m.rect.t + ws.y, r: m.rect.l + ws.x + ws.w, b: m.rect.t + ws.y + ws.h }, m.work),
        maximized: ws.maximized,
        fullscreen: ws.fullscreen,
    })
}

/// Make a saved rect usable on the monitor's work area: shrink to fit, and move it fully inside
/// if it is partly off-screen (e.g. the monitor's resolution or taskbar changed).
pub fn fit_rect(r: Rect, work: Rect) -> Rect {
    let (ww, wh) = (work.w().max(1), work.h().max(1));
    let w = r.w().clamp(320.min(ww), ww);
    let h = r.h().clamp(200.min(wh), wh);
    let mut out = Rect { l: r.l, t: r.t, r: r.l + w, b: r.t + h };
    if out.intersect_area(&work) < (w as i64 * h as i64) {
        let l = out.l.clamp(work.l, work.r - w);
        let t = out.t.clamp(work.t, work.b - h);
        out = Rect { l, t, r: l + w, b: t + h };
    }
    out
}

/// Record the window's state on monitor `m`. Returns true if the config changed.
pub fn record_placement(c: &mut Config, m: &MonitorDesc, normal: Rect, maximized: bool, fullscreen: bool) -> bool {
    let ws = WindowState {
        x: normal.l - m.rect.l,
        y: normal.t - m.rect.t,
        w: normal.w(),
        h: normal.h(),
        maximized,
        fullscreen,
        mon_w: m.rect.w(),
        mon_h: m.rect.h(),
    };
    let changed = c.windows.get(&m.key) != Some(&ws) || c.last_monitor.as_deref() != Some(m.key.as_str());
    c.windows.insert(m.key.clone(), ws);
    c.last_monitor = Some(m.key.clone());
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_roundtrip() {
        let l = parse("{}");
        assert!(l.warning.is_none());
        assert!(l.needs_save, "missing fields → write them out");
        assert_eq!(l.config, Config::default());
        let mut c = Config { hud: true, bar_pinned: true, ..Config::default() };
        c.set_mode(Mode::Sharp);
        c.host = Some("mac.local:7420".into());
        c.clipboard = false;
        c.audio = false;
        c.audio_muted = true;
        c.clipboard_sync_secrets = true;
        c.file_receive = false;
        c.download_dir = Some(r"D:\Inbox".into());
        c.file_max_total_bytes = 1 << 30;
        c.allowed_peers = vec!["192.168.50.4".into(), "192.168.50.0/24".into()];
        record_placement(
            &mut c,
            &MonitorDesc { key: r"\\.\DISPLAY2".into(), rect: Rect { l: 3840, t: 0, r: 6912, b: 1728 }, work: Rect { l: 3840, t: 0, r: 6912, b: 1680 } },
            Rect { l: 4000, t: 100, r: 5000, b: 700 },
            false,
            true,
        );
        let back = parse(&to_json(&c));
        assert_eq!(back.config, c);
        assert!(!back.needs_save);
        assert!(!back.legacy_password);
        assert_eq!(back.config.mode(), Some(Mode::Sharp));
        assert_eq!(back.config.windows[r"\\.\DISPLAY2"].x, 160);
        // new keys default sensibly when missing from an older file
        let old = parse(r#"{"version":1,"hud":true}"#).config;
        assert!(old.clipboard && !old.clipboard_sync_secrets && old.allowed_peers.is_empty());
        assert!(old.audio && !old.audio_muted);
        assert!(old.file_transfer && old.file_receive && old.download_dir.is_none());
        assert_eq!((old.file_max_total_bytes, old.file_max_files), (8 << 30, 10_000));
        assert_eq!(parse(r#"{"version":1,"download_dir":"  "}"#).config.download_dir, None);
    }

    #[test]
    fn migrates_legacy_v0() {
        let l = parse(r#"{"port": 7500, "password": "hunter2", "no_ctrl_as_cmd": true, "connect": "192.168.50.4"}"#);
        assert!(l.legacy_password);
        assert!(l.needs_save);
        assert_eq!(l.config.listen_port, 7500);
        assert_eq!(l.config.host.as_deref(), Some("192.168.50.4"));
        assert!(!l.config.ctrl_as_cmd);
        assert_eq!(l.config.version, CONFIG_VERSION);
        // the rewritten file never contains the password
        let j = to_json(&l.config);
        assert!(!j.contains("hunter2") && !j.contains("password"));
        // and it reloads cleanly
        let again = parse(&j);
        assert!(!again.needs_save && !again.legacy_password);
        assert_eq!(again.config, l.config);
    }

    #[test]
    fn password_removed_even_in_current_version() {
        let mut c = serde_json::to_value(Config::default()).unwrap();
        c["password"] = "x".into();
        let l = parse(&c.to_string());
        assert!(l.legacy_password);
        assert!(l.needs_save);
    }

    #[test]
    fn bad_values_fall_back_individually() {
        let l = parse(r#"{"version":1,"listen_port":"nope","mode":"ultra","hud":true,"host":"  "}"#);
        assert!(l.warning.as_deref().unwrap().contains("listen_port"));
        assert!(l.warning.as_deref().unwrap().contains("mode"));
        assert_eq!(l.config.listen_port, DEFAULT_PORT);
        assert_eq!(l.config.mode, None);
        assert!(l.config.hud, "valid fields survive");
        assert_eq!(l.config.host, None);
        let l = parse("[1,2]");
        assert!(l.warning.is_some());
        assert_eq!(l.config, Config::default());
        let l = parse("{not json");
        assert!(l.warning.as_deref().unwrap().contains("parse error"));
        // future version with unknown keys: tolerated
        let l = parse(r#"{"version":7,"hud":true,"new_thing":{"a":1}}"#);
        assert!(l.warning.is_none());
        assert!(l.config.hud);
    }

    #[test]
    fn load_save_files() {
        let dir = std::env::temp_dir().join(format!("glide-cfg-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("sub").join(CONFIG_FILE);
        let l = load(&path);
        assert!(l.needs_save && l.warning.is_none());
        let mut c = l.config;
        c.hud = true;
        save(&path, &c).unwrap();
        let l = load(&path);
        assert_eq!(l.config, c);
        assert!(!l.needs_save);
        // corrupt file is moved aside, defaults used
        std::fs::write(&path, "{oops").unwrap();
        let l = load(&path);
        assert!(l.warning.is_some() && l.needs_save);
        assert_eq!(l.config, Config::default());
        assert!(path.with_extension("json.bad").exists());
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn store_open_update() {
        let dir = std::env::temp_dir().join(format!("glide-store-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // first run: defaults are written out
        let (mut st, warn) = Store::open(Some(dir.clone()));
        assert!(warn.is_empty());
        assert!(dir.join(CONFIG_FILE).exists());
        st.update(|c| c.hud = true);
        assert!(load(&dir.join(CONFIG_FILE)).config.hud);
        // legacy plaintext password: dropped from the file with a notice
        std::fs::write(dir.join(CONFIG_FILE), r#"{"port": 7444, "password": "pw"}"#).unwrap();
        let (st, warn) = Store::open(Some(dir.clone()));
        assert!(warn.iter().any(|w| w.contains("password")));
        assert_eq!(st.config.listen_port, 7444);
        let text = std::fs::read_to_string(dir.join(CONFIG_FILE)).unwrap();
        assert!(!text.contains("pw\"") && text.contains("7444"));
        // no dir: in-memory only
        let (mut st, _) = Store::open(None);
        st.update(|c| c.hud = true);
        assert!(st.config.hud && st.path().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_dir_resolution() {
        let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|p| p.0 == k).map(|p| p.1.to_string());
        assert_eq!(config_dir_from(env(&[("GLIDE_CONFIG_DIR", "/x"), ("APPDATA", "/a")])), Some(PathBuf::from("/x")));
        if cfg!(windows) {
            assert_eq!(config_dir_from(env(&[("APPDATA", "/a")])), Some(PathBuf::from("/a").join("Glide")));
        } else {
            assert_eq!(config_dir_from(env(&[("HOME", "/h")])), Some(PathBuf::from("/h/.config/glide")));
        }
    }

    #[test]
    fn pinned_hosts_roundtrip_and_validation() {
        let mut c = Config::default();
        let key = "ab".repeat(32);
        c.pinned_hosts.insert("192.168.50.4:7420".into(), PinnedHost { key: key.clone(), name: "Mac".into(), paired: "2026-11-06T13:00:00Z".into() });
        let back = parse(&to_json(&c));
        assert_eq!(back.config, c);
        assert_eq!(back.config.pinned_key("192.168.50.4:7420"), Some([0xab; 32]));
        assert_eq!(back.config.pinned_key("listen:7420"), None);
        // a malformed key is dropped (fail closed: treated as not paired), others survive
        let l = parse(r#"{"version":1,"hud":true,"pinned_hosts":{"a:1":{"key":"zz","name":"x"},"b:2":{"key":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}}}"#);
        assert!(l.warning.as_deref().unwrap().contains("pinned_hosts"));
        assert_eq!(l.config.pinned_hosts.len(), 1);
        assert_eq!(l.config.pinned_key("b:2"), Some([0xcd; 32]));
        assert!(l.config.hud);
        // targets
        assert_eq!(pin_target(&TargetSpec::Connect("Mac.Local".into())), "mac.local:7420");
        assert_eq!(pin_target(&TargetSpec::Connect("192.168.50.4:7421".into())), "192.168.50.4:7421");
        assert_eq!(pin_target(&TargetSpec::Listen(7420)), "listen:7420");
        // timestamps
        assert_eq!(rfc3339_utc(std::time::UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_utc(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_793_970_309)), "2026-11-06T13:05:09Z");
        assert_eq!(rfc3339_utc(std::time::UNIX_EPOCH + std::time::Duration::from_secs(951_782_400)), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn target_precedence() {
        let mut c = Config::default();
        assert_eq!(resolve_target(None, None, &c), TargetSpec::Listen(7420));
        c.listen_port = 7500;
        assert_eq!(resolve_target(None, None, &c), TargetSpec::Listen(7500));
        c.host = Some("mac:7420".into());
        assert_eq!(resolve_target(None, None, &c), TargetSpec::Connect("mac:7420".into()));
        assert_eq!(resolve_target(None, Some(7421), &c), TargetSpec::Listen(7421));
        assert_eq!(resolve_target(Some("other"), Some(7421), &c), TargetSpec::Connect("other".into()));
    }

    #[test]
    fn mode_precedence() {
        let mut c = Config::default();
        assert_eq!(resolve_mode(None, &c, true).0, Mode::Hybrid);
        assert_eq!(resolve_mode(None, &c, false).0, Mode::Fast);
        c.set_mode(Mode::Sharp);
        assert_eq!(resolve_mode(None, &c, true).0, Mode::Sharp);
        assert_eq!(resolve_mode(Some(Mode::Fast), &c, true).0, Mode::Fast);
        let (m, note) = resolve_mode(None, &c, false);
        assert_eq!(m, Mode::Fast);
        assert!(note.is_some());
    }

    fn mons() -> Vec<MonitorDesc> {
        vec![
            MonitorDesc { key: "A".into(), rect: Rect { l: 0, t: 0, r: 3840, b: 2160 }, work: Rect { l: 0, t: 0, r: 3840, b: 2112 } },
            MonitorDesc { key: "B".into(), rect: Rect { l: 3840, t: 0, r: 5760, b: 1080 }, work: Rect { l: 3840, t: 0, r: 5760, b: 1040 } },
        ]
    }

    #[test]
    fn placement_restore() {
        let ms = mons();
        let mut c = Config::default();
        assert_eq!(choose_placement(&c, &ms, Some(0)), None, "nothing saved");
        // windowed on A, fullscreen on B (last)
        assert!(record_placement(&mut c, &ms[0], Rect { l: 100, t: 100, r: 1700, b: 1000 }, false, false));
        assert!(record_placement(&mut c, &ms[1], Rect { l: 4000, t: 50, r: 5000, b: 650 }, false, true));
        assert!(!record_placement(&mut c, &ms[1], Rect { l: 4000, t: 50, r: 5000, b: 650 }, false, true), "unchanged");
        let p = choose_placement(&c, &ms, Some(0)).unwrap();
        assert_eq!(p, Placement { monitor: 1, rect: Rect { l: 4000, t: 50, r: 5000, b: 650 }, maximized: false, fullscreen: true });
        // monitor B unplugged → fall back to the cursor monitor's saved state
        let p = choose_placement(&c, &ms[..1], Some(0)).unwrap();
        assert_eq!(p.monitor, 0);
        assert_eq!(p.rect, Rect { l: 100, t: 100, r: 1700, b: 1000 });
        assert!(!p.fullscreen);
        // B moved to the left of A: relative position follows it
        let moved = vec![
            ms[0].clone(),
            MonitorDesc { key: "B".into(), rect: Rect { l: -1920, t: 0, r: 0, b: 1080 }, work: Rect { l: -1920, t: 0, r: 0, b: 1040 } },
        ];
        let p = choose_placement(&c, &moved, None).unwrap();
        assert_eq!(p.rect, Rect { l: -1760, t: 50, r: -760, b: 650 });
    }

    #[test]
    fn fit_rect_clamps() {
        let work = Rect { l: 0, t: 0, r: 1920, b: 1040 };
        // fully inside: unchanged
        let r = Rect { l: 10, t: 10, r: 810, b: 610 };
        assert_eq!(fit_rect(r, work), r);
        // hanging off the right/bottom: moved in
        assert_eq!(fit_rect(Rect { l: 1500, t: 900, r: 2300, b: 1500 }, work), Rect { l: 1120, t: 440, r: 1920, b: 1040 });
        // bigger than the work area: shrunk
        assert_eq!(fit_rect(Rect { l: -50, t: -50, r: 3000, b: 2000 }, work), work);
        // degenerate saved size: minimum size
        assert_eq!(fit_rect(Rect { l: 0, t: 0, r: 5, b: 5 }, work), Rect { l: 0, t: 0, r: 320, b: 200 });
    }
}
