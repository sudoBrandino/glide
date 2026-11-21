//! The Settings window's model, platform independent (the Win32 UI is `win::settings`).
//!
//! - `Settings`: the values the window edits, read from the config (`from_config`) plus the one
//!   thing that lives outside it (start at sign-in, a registry value).
//! - `Draft`: what the window shows; the free-text fields stay text until `validate` turns the
//!   draft back into `Settings`, or names the field that is wrong and why.
//! - `diff`: what changed, split into what applies at once (`Live`), what only a restart picks
//!   up, and whether start at sign-in must be written.
//! - `apply`: write the changed fields into a config. Only fields that changed are touched, so
//!   anything else that changed meanwhile (a pin the session thread wrote, a placement) stays.

use crate::config::{mode_from_str, Config};
use crate::protocol::Mode;

/// Largest transfer limit the window accepts, in GB (GiB, as Explorer counts them).
pub const MAX_TRANSFER_GB: f64 = 16_384.0;
/// Most files per transfer the window accepts.
pub const MAX_FILES: u32 = 1_000_000;
const GIB: f64 = (1u64 << 30) as f64;

/// The pages of the window, in list order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Page {
    General,
    Picture,
    Input,
    Audio,
    Clipboard,
    Files,
    Network,
    Advanced,
}

impl Page {
    pub const ALL: [Page; 8] = [Page::General, Page::Picture, Page::Input, Page::Audio, Page::Clipboard, Page::Files, Page::Network, Page::Advanced];

    pub fn title(self) -> &'static str {
        match self {
            Page::General => "General",
            Page::Picture => "Picture",
            Page::Input => "Keyboard & mouse",
            Page::Audio => "Audio",
            Page::Clipboard => "Clipboard",
            Page::Files => "Files",
            Page::Network => "Network & security",
            Page::Advanced => "Advanced",
        }
    }
}

/// Stream mode choice; `None` in the config is Automatic.
pub const MODES: [Option<Mode>; 4] = [None, Some(Mode::Hybrid), Some(Mode::Fast), Some(Mode::Sharp)];

pub fn mode_label(m: Option<Mode>) -> &'static str {
    match m {
        None => "Automatic",
        Some(Mode::Hybrid) => "Hybrid",
        Some(Mode::Fast) => "Fast",
        Some(Mode::Sharp) => "Sharp",
    }
}

/// One line about a mode choice, for under the list. `has444`: this PC decodes HEVC 4:4:4.
pub fn mode_help(m: Option<Mode>, has444: bool) -> String {
    let text = match m {
        None if has444 => "Hybrid on this PC: fast video with sharp text.",
        None => "Fast on this PC (it can't decode HEVC 4:4:4).",
        Some(Mode::Hybrid) => "Smooth video, and text sharpened to full color detail once the screen settles.",
        Some(Mode::Fast) => "Lowest latency and bandwidth. Fine text and colored edges are a little soft.",
        Some(Mode::Sharp) => "Full color detail all the time, for text and design work. Uses more bandwidth.",
    };
    let mut s = text.to_string();
    if !has444 && matches!(m, Some(Mode::Hybrid | Mode::Sharp)) {
        s.push_str(" This PC can't decode HEVC 4:4:4, so Glide uses Fast.");
    }
    s
}

/// One host key pinned by pairing, as the Network page lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedRow {
    /// The `pinned_hosts` key ("host:port" or "listen:PORT").
    pub key: String,
    pub name: String,
    /// "mac.local:7420" or "Mac connects on port 7420".
    pub target: String,
    /// Date only ("2026-11-06"), or "".
    pub paired: String,
}

/// The values the Settings window edits.
#[derive(Debug, Clone, PartialEq)]
pub struct Settings {
    /// Start Glide when the user signs in (HKCU Run value; not in the config).
    pub autostart: bool,
    pub connect_at_signin: bool,
    pub bar_pinned: bool,
    pub hud: bool,
    /// None = automatic.
    pub mode: Option<Mode>,
    pub ctrl_as_cmd: bool,
    pub natural_scrolling: bool,
    pub audio: bool,
    pub audio_muted: bool,
    pub clipboard: bool,
    pub clipboard_sync_secrets: bool,
    pub file_transfer: bool,
    pub file_receive: bool,
    /// None = `<Downloads>\Glide`.
    pub download_dir: Option<String>,
    pub file_max_total_bytes: u64,
    pub file_max_files: u32,
    pub listen_port: u16,
    pub accept_incoming: bool,
    pub allowed_peers: Vec<String>,
    /// Mac displays chosen in the viewer are remembered (`last_display` not empty). Turning it
    /// off forgets them.
    pub remembered_displays: usize,
    /// `pinned_hosts` keys still paired (Unpair removes one).
    pub paired: Vec<String>,
}

impl Settings {
    pub fn from_config(c: &Config, autostart: bool) -> Settings {
        Settings {
            autostart,
            connect_at_signin: c.connect_at_signin,
            bar_pinned: c.bar_pinned,
            hud: c.hud,
            mode: c.mode.as_deref().and_then(mode_from_str),
            ctrl_as_cmd: c.ctrl_as_cmd,
            natural_scrolling: c.natural_scrolling,
            audio: c.audio,
            audio_muted: c.audio_muted,
            clipboard: c.clipboard,
            clipboard_sync_secrets: c.clipboard_sync_secrets,
            file_transfer: c.file_transfer,
            file_receive: c.file_receive,
            download_dir: c.download_dir.clone().filter(|d| !d.trim().is_empty()),
            file_max_total_bytes: c.file_max_total_bytes,
            file_max_files: c.file_max_files,
            listen_port: c.listen_port,
            accept_incoming: c.accept_incoming,
            allowed_peers: c.allowed_peers.clone(),
            remembered_displays: c.last_display.len(),
            paired: c.pinned_hosts.keys().cloned().collect(),
        }
    }

    /// Defaults for everything the window edits, except what isn't a preference: start at sign-in
    /// (left as it is), pairings, remembered displays and the allowlist (security state, not
    /// settings; they have their own buttons).
    pub fn reset(&self) -> Settings {
        let d = Settings::from_config(&Config::default(), self.autostart);
        Settings { allowed_peers: self.allowed_peers.clone(), remembered_displays: self.remembered_displays, paired: self.paired.clone(), ..d }
    }
}

/// The rows of the "Paired Macs" list for the keys in `paired`, in that order.
pub fn paired_rows(c: &Config, paired: &[String]) -> Vec<PairedRow> {
    paired
        .iter()
        .filter_map(|k| {
            let p = c.pinned_hosts.get(k)?;
            let target = match k.strip_prefix("listen:") {
                Some(port) => format!("Mac connects on port {port}"),
                None => k.clone(),
            };
            let name = if p.name.trim().is_empty() { "Mac".to_string() } else { p.name.trim().to_string() };
            Some(PairedRow { key: k.clone(), name, target, paired: p.paired.get(..10).unwrap_or("").to_string() })
        })
        .collect()
}

/// Which field of the window a validation error is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    DownloadDir,
    MaxSize,
    MaxFiles,
    ListenPort,
    AllowedPeers,
}

impl Field {
    pub fn page(self) -> Page {
        match self {
            Field::DownloadDir | Field::MaxSize | Field::MaxFiles => Page::Files,
            Field::ListenPort | Field::AllowedPeers => Page::Network,
        }
    }
}

/// What the window shows: `values` for the checkboxes and lists, text for the typed fields.
#[derive(Debug, Clone, PartialEq)]
pub struct Draft {
    pub values: Settings,
    /// Empty = the default folder.
    pub download_dir: String,
    /// GB, as typed ("8", "0.5").
    pub max_size_gb: String,
    pub max_files: String,
    pub listen_port: String,
    /// One IP or CIDR per line.
    pub allowed_peers: String,
}

impl Draft {
    pub fn from_settings(s: &Settings) -> Draft {
        Draft {
            values: s.clone(),
            download_dir: s.download_dir.clone().unwrap_or_default(),
            max_size_gb: format_gb(s.file_max_total_bytes),
            max_files: s.file_max_files.to_string(),
            listen_port: s.listen_port.to_string(),
            allowed_peers: s.allowed_peers.join("\r\n"),
        }
    }
}

/// Bytes → "8", "0.5", "1.25" (GiB, at most two decimals).
pub fn format_gb(bytes: u64) -> String {
    let s = format!("{:.2}", bytes as f64 / GIB);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "0" {
        "0.01".into() // under 10 MB: show the smallest value the field accepts
    } else {
        s.to_string()
    }
}

fn parse_gb(text: &str) -> Result<u64, String> {
    let t = text.trim().replace(',', ".");
    let t = t.strip_suffix("GB").or_else(|| t.strip_suffix("gb")).unwrap_or(&t).trim();
    let v: f64 = t.parse().map_err(|_| format!("Enter the largest transfer in GB, for example 8 or 0.5 (not “{}”).", text.trim()))?;
    if !v.is_finite() || v < 0.01 || v > MAX_TRANSFER_GB {
        return Err(format!("The largest transfer must be between 0.01 and {MAX_TRANSFER_GB} GB."));
    }
    Ok((v * GIB).round() as u64)
}

/// The arguments for the restart Settings offers: this run's own (so a Mac address or `--listen`
/// given on the command line keeps winning over the saved connection), without the one-shot
/// launch flags, plus `--after-setup` (don't open the setup dialog again). `--startup` is dropped
/// too: someone is at the PC changing settings, so the restarted viewer connects.
pub fn restart_args(current: &[String]) -> Vec<String> {
    let one_shot = ["--setup", "--after-setup", crate::signin::STARTUP_FLAG];
    current.iter().filter(|a| !one_shot.contains(&a.as_str())).cloned().chain(std::iter::once("--after-setup".to_string())).collect()
}

/// Does `s` look like a full Windows folder path ("C:\…", "\\server\share", or starting with an
/// environment variable such as "%USERPROFILE%\…")?
pub fn looks_like_folder(s: &str) -> bool {
    let b = s.as_bytes();
    let drive = b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/');
    let unc = s.starts_with("\\\\") && s.len() > 2;
    let var = s.starts_with('%') && s[1..].contains('%');
    let bad = s.chars().any(|c| matches!(c, '<' | '>' | '"' | '|' | '?' | '*') || c.is_control());
    (drive || unc || var) && !bad
}

/// Check the typed fields and return the settings they describe, or the first bad field.
pub fn validate(d: &Draft) -> Result<Settings, (Field, String)> {
    let mut s = d.values.clone();

    let dir = d.download_dir.trim();
    s.download_dir = if dir.is_empty() {
        None
    } else if looks_like_folder(dir) {
        Some(dir.to_string())
    } else {
        return Err((Field::DownloadDir, "Choose a full folder path, such as D:\\Downloads\\Glide (Browse…), or leave it empty for the default.".into()));
    };

    // Untouched (still the text the saved value formats to): keep the exact saved bytes, so a
    // value with more precision than the field shows ("0.125") doesn't drift to "0.12" on OK.
    if d.max_size_gb.trim() != format_gb(d.values.file_max_total_bytes) {
        s.file_max_total_bytes = parse_gb(&d.max_size_gb).map_err(|e| (Field::MaxSize, e))?;
    }
    s.file_max_files = match d.max_files.trim().parse::<u64>() {
        Ok(n) if (1..=MAX_FILES as u64).contains(&n) => n as u32,
        _ => return Err((Field::MaxFiles, format!("The most files per transfer must be a whole number from 1 to {MAX_FILES}."))),
    };

    s.listen_port = match d.listen_port.trim().parse::<u32>() {
        Ok(p) if (1..=65535).contains(&p) => p as u16,
        _ => return Err((Field::ListenPort, "The port must be a number from 1 to 65535 (Glide uses 7420).".into())),
    };

    let mut peers: Vec<String> = Vec::new();
    for (i, line) in d.allowed_peers.lines().enumerate() {
        let e = line.trim();
        if e.is_empty() {
            continue;
        }
        if crate::peers::parse_net(e).is_err() {
            return Err((
                Field::AllowedPeers,
                format!("Line {}: “{e}” isn't an IP address or range. Use one per line, like 192.168.1.50 or 192.168.1.0/24.", i + 1),
            ));
        }
        if !peers.iter().any(|p| p.eq_ignore_ascii_case(e)) {
            peers.push(e.to_string());
        }
    }
    s.allowed_peers = peers;
    Ok(s)
}

/// A change the running viewer applies at once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Live {
    Hud(bool),
    BarPinned(bool),
    /// None = automatic.
    Mode(Option<Mode>),
    CtrlAsCmd(bool),
    NaturalScrolling(bool),
    AudioMuted(bool),
    Clipboard(bool),
    ClipboardSecrets(bool),
}

/// What the running viewer is doing, for `diff`.
#[derive(Debug, Clone, Default)]
pub struct Running {
    /// Pin-store keys of the target it runs with (`pin_target`, and `pin_fallback` if any).
    pub pins: Vec<String>,
    /// Audio playback was started (config "audio" and no `--no-audio`).
    pub audio: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Changes {
    pub live: Vec<Live>,
    /// What only takes effect after a restart, as words for a sentence ("the listen port").
    pub restart: Vec<&'static str>,
    /// Start at sign-in must be turned on / off.
    pub autostart: Option<bool>,
    /// Anything at all changed (including what needs nothing but saving).
    pub any: bool,
}

pub fn diff(before: &Settings, after: &Settings, run: &Running) -> Changes {
    let mut ch = Changes { any: before != after, ..Default::default() };
    let mut live = |cond: bool, l: Live| {
        if cond {
            ch.live.push(l);
        }
    };
    live(before.hud != after.hud, Live::Hud(after.hud));
    live(before.bar_pinned != after.bar_pinned, Live::BarPinned(after.bar_pinned));
    live(before.mode != after.mode, Live::Mode(after.mode));
    live(before.ctrl_as_cmd != after.ctrl_as_cmd, Live::CtrlAsCmd(after.ctrl_as_cmd));
    live(before.natural_scrolling != after.natural_scrolling, Live::NaturalScrolling(after.natural_scrolling));
    // Muting needs running playback; otherwise it is saved for the next start.
    live(before.audio_muted != after.audio_muted && run.audio && after.audio, Live::AudioMuted(after.audio_muted));
    live(before.clipboard != after.clipboard, Live::Clipboard(after.clipboard));
    live(before.clipboard_sync_secrets != after.clipboard_sync_secrets, Live::ClipboardSecrets(after.clipboard_sync_secrets));

    let mut restart = |cond: bool, what: &'static str| {
        if cond && !ch.restart.contains(&what) {
            ch.restart.push(what);
        }
    };
    restart(before.audio != after.audio, "Mac audio");
    restart(
        before.file_transfer != after.file_transfer
            || before.file_receive != after.file_receive
            || before.download_dir != after.download_dir
            || before.file_max_total_bytes != after.file_max_total_bytes
            || before.file_max_files != after.file_max_files,
        "file transfer",
    );
    restart(before.listen_port != after.listen_port, "the listen port");
    restart(before.accept_incoming != after.accept_incoming, "letting the Mac connect");
    let unpaired_running = before.paired.iter().any(|k| !after.paired.contains(k) && run.pins.contains(k));
    restart(unpaired_running, "unpairing the current Mac");

    if before.autostart != after.autostart {
        ch.autostart = Some(after.autostart);
    }
    ch
}

/// "a", "a and b", "a, b and c".
pub fn join_words(words: &[&str]) -> String {
    match words {
        [] => String::new(),
        [a] => a.to_string(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// Write the fields that differ between `before` and `after` into `c` (start at sign-in is not
/// in the config; the caller writes it).
pub fn apply(c: &mut Config, before: &Settings, after: &Settings) {
    macro_rules! copy {
        ($($f:ident),*) => {$(
            if before.$f != after.$f {
                c.$f = after.$f.clone();
            }
        )*};
    }
    copy!(
        connect_at_signin,
        bar_pinned,
        hud,
        ctrl_as_cmd,
        natural_scrolling,
        audio,
        audio_muted,
        clipboard,
        clipboard_sync_secrets,
        file_transfer,
        file_receive,
        download_dir,
        file_max_total_bytes,
        file_max_files,
        allowed_peers
    );
    if before.mode != after.mode {
        c.mode = after.mode.map(|m| m.name().to_string());
    }
    if before.accept_incoming != after.accept_incoming {
        c.accept_incoming = after.accept_incoming;
        // The active saved connection carries it too (`connections::sync_from_host` mirrors it).
        if let Some(id) = c.active_connection.clone() {
            if let Some(s) = c.connections.iter_mut().find(|s| s.id == id) {
                s.accept_incoming = after.accept_incoming;
            }
        }
    }
    for k in before.paired.iter().filter(|k| !after.paired.contains(k)) {
        c.pinned_hosts.remove(k);
    }
    if before.remembered_displays > 0 && after.remembered_displays == 0 {
        c.last_display.clear();
    }
    if before.listen_port != after.listen_port {
        let (old, new) = (format!("listen:{}", before.listen_port), format!("listen:{}", after.listen_port));
        // A Mac paired while it connected to this PC stays paired on the new port (pins and the
        // remembered display are keyed by "listen:PORT").
        if !c.pinned_hosts.contains_key(&new) {
            if let Some(p) = c.pinned_hosts.remove(&old) {
                c.pinned_hosts.insert(new.clone(), p);
            }
        }
        if !c.last_display.contains_key(&new) {
            if let Some(d) = c.last_display.remove(&old) {
                c.last_display.insert(new, d);
            }
        }
        c.listen_port = after.listen_port;
    }
}

/// Plain-text rendering of a draft, page by page (test hook dumps and unit tests).
pub fn to_text(d: &Draft, has444: bool) -> String {
    let v = &d.values;
    let b = |x: bool| if x { "on" } else { "off" };
    let mut out = String::new();
    let mut line = |s: String| {
        out.push_str(&s);
        out.push('\n');
    };
    line(format!("[{}]", Page::General.title()));
    line(format!("start at sign-in: {}; connect at sign-in: {}", b(v.autostart), b(v.connect_at_signin)));
    line(format!("connection bar pinned: {}; stats overlay: {}", b(v.bar_pinned), b(v.hud)));
    line(format!("[{}]", Page::Picture.title()));
    line(format!("mode: {} ({})", mode_label(v.mode), mode_help(v.mode, has444)));
    line(format!("remembered Mac displays: {}", v.remembered_displays));
    line(format!("[{}]", Page::Input.title()));
    line(format!("ctrl as command: {}; natural scrolling: {}", b(v.ctrl_as_cmd), b(v.natural_scrolling)));
    line(format!("[{}]", Page::Audio.title()));
    line(format!("audio: {}; muted: {}", b(v.audio), b(v.audio_muted)));
    line(format!("[{}]", Page::Clipboard.title()));
    line(format!("clipboard: {}; private items: {}", b(v.clipboard), b(v.clipboard_sync_secrets)));
    line(format!("[{}]", Page::Files.title()));
    line(format!(
        "file transfer: {}; receive: {}; folder: {}",
        b(v.file_transfer),
        b(v.file_receive),
        if d.download_dir.is_empty() { "(default)" } else { &d.download_dir }
    ));
    line(format!("largest transfer: {} GB; most files: {}", d.max_size_gb, d.max_files));
    line(format!("[{}]", Page::Network.title()));
    line(format!("listen port: {}; accept incoming: {}", d.listen_port, b(v.accept_incoming)));
    line(format!(
        "allowed: {}",
        if d.allowed_peers.trim().is_empty() { "(first Mac that connects)".to_string() } else { d.allowed_peers.lines().collect::<Vec<_>>().join(", ") }
    ));
    line(format!("paired: {}", v.paired.join(", ")));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PinnedHost;

    fn pin(name: &str) -> PinnedHost {
        PinnedHost { key: "ab".repeat(32), name: name.into(), paired: "2026-11-06T13:05:09Z".into() }
    }

    fn base() -> Config {
        let mut c = Config::default();
        c.pinned_hosts.insert("listen:7420".into(), pin("Mac mini"));
        c.pinned_hosts.insert("studio.local:7420".into(), pin("Studio"));
        c
    }

    #[test]
    fn round_trip_without_edits_changes_nothing() {
        let c = base();
        let s = Settings::from_config(&c, true);
        let d = Draft::from_settings(&s);
        let v = validate(&d).unwrap();
        assert_eq!(v, s);
        let ch = diff(&s, &v, &Running::default());
        assert!(!ch.any && ch.live.is_empty() && ch.restart.is_empty() && ch.autostart.is_none());
        let mut c2 = c.clone();
        apply(&mut c2, &s, &v);
        assert_eq!(c2, c);
    }

    #[test]
    fn mode_round_trip() {
        let mut c = Config::default();
        for m in MODES {
            c.mode = m.map(|m| m.name().to_string());
            assert_eq!(Settings::from_config(&c, false).mode, m);
        }
        let before = Settings::from_config(&Config::default(), false);
        let after = Settings { mode: Some(Mode::Sharp), ..before.clone() };
        apply(&mut c, &before, &after);
        assert_eq!(c.mode.as_deref(), Some("sharp"));
        let back = Settings { mode: None, ..after.clone() };
        apply(&mut c, &after, &back);
        assert_eq!(c.mode, None);
        assert!(mode_help(Some(Mode::Sharp), false).contains("uses Fast"));
        assert!(!mode_help(Some(Mode::Fast), false).contains("uses Fast"));
        assert!(mode_help(None, true).starts_with("Hybrid"));
    }

    #[test]
    fn validation_errors_name_the_field() {
        let s = Settings::from_config(&Config::default(), false);
        let ok = Draft::from_settings(&s);
        let bad = |f: fn(&mut Draft)| {
            let mut d = ok.clone();
            f(&mut d);
            validate(&d).unwrap_err().0
        };
        assert_eq!(bad(|d| d.listen_port = "0".into()), Field::ListenPort);
        assert_eq!(bad(|d| d.listen_port = "65536".into()), Field::ListenPort);
        assert_eq!(bad(|d| d.listen_port = "port".into()), Field::ListenPort);
        assert_eq!(bad(|d| d.max_files = "0".into()), Field::MaxFiles);
        assert_eq!(bad(|d| d.max_files = "1.5".into()), Field::MaxFiles);
        assert_eq!(bad(|d| d.max_files = "2000000".into()), Field::MaxFiles);
        assert_eq!(bad(|d| d.max_size_gb = "0".into()), Field::MaxSize);
        assert_eq!(bad(|d| d.max_size_gb = "lots".into()), Field::MaxSize);
        assert_eq!(bad(|d| d.max_size_gb = "99999".into()), Field::MaxSize);
        assert_eq!(bad(|d| d.download_dir = "Downloads".into()), Field::DownloadDir);
        assert_eq!(bad(|d| d.download_dir = "C:\\a|b".into()), Field::DownloadDir);
        assert_eq!(bad(|d| d.allowed_peers = "192.168.1.50\r\nnot-an-ip".into()), Field::AllowedPeers);
        let mut d = ok.clone();
        d.allowed_peers = "192.168.1.50\r\nnope".into();
        assert!(validate(&d).unwrap_err().1.starts_with("Line 2:"));
        assert_eq!(Field::ListenPort.page(), Page::Network);
        assert_eq!(Field::MaxSize.page(), Page::Files);
    }

    #[test]
    fn typed_fields_parse() {
        let s = Settings::from_config(&Config::default(), false);
        let mut d = Draft::from_settings(&s);
        assert_eq!(d.max_size_gb, "8");
        d.max_size_gb = " 0,5 GB ".into();
        d.max_files = " 250 ".into();
        d.listen_port = "7421".into();
        d.download_dir = "  %USERPROFILE%\\Glide  ".into();
        d.allowed_peers = "\r\n 192.168.1.50 \r\n192.168.1.0/24\r\n192.168.1.50\r\n".into();
        let v = validate(&d).unwrap();
        assert_eq!(v.file_max_total_bytes, 1 << 29);
        assert_eq!(v.file_max_files, 250);
        assert_eq!(v.listen_port, 7421);
        assert_eq!(v.download_dir.as_deref(), Some("%USERPROFILE%\\Glide"));
        assert_eq!(v.allowed_peers, vec!["192.168.1.50", "192.168.1.0/24"]);
        d.download_dir = "   ".into();
        assert_eq!(validate(&d).unwrap().download_dir, None);
    }

    #[test]
    fn restart_keeps_the_launch_target() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(restart_args(&[]), v(&["--after-setup"]));
        assert_eq!(restart_args(&v(&["10.0.0.5", "--no-audio"])), v(&["10.0.0.5", "--no-audio", "--after-setup"]));
        assert_eq!(restart_args(&v(&["--listen", "--startup", "--after-setup", "--setup"])), v(&["--listen", "--after-setup"]));
    }

    #[test]
    fn untouched_size_keeps_exact_bytes() {
        let mut s = Settings::from_config(&Config::default(), false);
        s.file_max_total_bytes = (1 << 30) / 8; // 0.125 GB, shown as "0.12"
        let d = Draft::from_settings(&s);
        assert_eq!(d.max_size_gb, "0.12");
        assert_eq!(validate(&d).unwrap().file_max_total_bytes, (1 << 30) / 8);
        let mut d2 = d.clone();
        d2.max_size_gb = "0.25".into();
        assert_eq!(validate(&d2).unwrap().file_max_total_bytes, 1 << 28);
    }

    #[test]
    fn gb_formatting() {
        assert_eq!(format_gb(8 << 30), "8");
        assert_eq!(format_gb(1 << 29), "0.5");
        assert_eq!(format_gb((5 << 30) / 4), "1.25");
        assert_eq!(format_gb(1000), "0.01");
        assert!(looks_like_folder("D:\\Downloads"));
        assert!(looks_like_folder("\\\\nas\\share\\glide"));
        assert!(looks_like_folder("%USERPROFILE%\\Downloads"));
        assert!(!looks_like_folder("Downloads\\Glide"));
        assert!(!looks_like_folder("\\\\"));
    }

    #[test]
    fn diff_splits_live_and_restart() {
        let s = Settings::from_config(&base(), false);
        let run = Running { pins: vec!["studio.local:7420".into()], audio: true };
        let after = Settings {
            hud: true,
            bar_pinned: true,
            mode: Some(Mode::Fast),
            ctrl_as_cmd: false,
            natural_scrolling: true,
            audio_muted: true,
            clipboard: false,
            clipboard_sync_secrets: true,
            connect_at_signin: true,
            autostart: true,
            allowed_peers: vec!["192.168.1.50".into()],
            ..s.clone()
        };
        let ch = diff(&s, &after, &run);
        assert!(ch.any);
        assert!(ch.restart.is_empty(), "{:?}", ch.restart);
        assert_eq!(ch.autostart, Some(true));
        assert_eq!(
            ch.live,
            vec![
                Live::Hud(true),
                Live::BarPinned(true),
                Live::Mode(Some(Mode::Fast)),
                Live::CtrlAsCmd(false),
                Live::NaturalScrolling(true),
                Live::AudioMuted(true),
                Live::Clipboard(false),
                Live::ClipboardSecrets(true),
            ]
        );

        // Without running audio, muting is only saved.
        let ch = diff(&s, &Settings { audio_muted: true, ..s.clone() }, &Running { audio: false, ..run.clone() });
        assert!(ch.any && ch.live.is_empty() && ch.restart.is_empty());

        let after = Settings { audio: false, file_receive: false, file_max_files: 5, listen_port: 7421, accept_incoming: false, ..s.clone() };
        let ch = diff(&s, &after, &run);
        assert!(ch.live.is_empty());
        assert_eq!(ch.restart, vec!["Mac audio", "file transfer", "the listen port", "letting the Mac connect"]);
        assert_eq!(join_words(&ch.restart), "Mac audio, file transfer, the listen port and letting the Mac connect");
        assert_eq!(join_words(&["a", "b"]), "a and b");
        assert_eq!(join_words(&["a"]), "a");
    }

    #[test]
    fn unpairing_restarts_only_for_the_running_target() {
        let c = base();
        let s = Settings::from_config(&c, false);
        let run = Running { pins: vec!["studio.local:7420".into(), "listen:7420".into()], audio: true };
        let other = Running { pins: vec!["elsewhere:7420".into()], audio: true };
        let after = Settings { paired: vec!["studio.local:7420".into()], ..s.clone() };
        assert_eq!(diff(&s, &after, &run).restart, vec!["unpairing the current Mac"]);
        assert!(diff(&s, &after, &other).restart.is_empty());
        let mut c2 = c.clone();
        apply(&mut c2, &s, &after);
        assert!(!c2.pinned_hosts.contains_key("listen:7420"));
        assert!(c2.pinned_hosts.contains_key("studio.local:7420"));
        let rows = paired_rows(&c, &s.paired);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].target, "Mac connects on port 7420");
        assert_eq!(rows[0].name, "Mac mini");
        assert_eq!(rows[0].paired, "2026-11-06");
        assert_eq!(rows[1].target, "studio.local:7420");
    }

    #[test]
    fn apply_touches_only_changed_fields() {
        let c = base();
        let s = Settings::from_config(&c, false);
        let after = Settings { hud: true, ..s.clone() };
        // Meanwhile the session thread pinned an IP and another host.
        let mut live = c.clone();
        live.allowed_peers = vec!["192.168.1.50".into()];
        live.pinned_hosts.insert("new.local:7420".into(), pin("New"));
        apply(&mut live, &s, &after);
        assert!(live.hud);
        assert_eq!(live.allowed_peers, vec!["192.168.1.50"]);
        assert!(live.pinned_hosts.contains_key("new.local:7420"));
    }

    #[test]
    fn port_change_keeps_listen_pairing_and_display() {
        let mut c = base();
        c.last_display.insert("listen:7420".into(), Default::default());
        let s = Settings::from_config(&c, false);
        let after = Settings { listen_port: 7500, ..s.clone() };
        apply(&mut c, &s, &after);
        assert_eq!(c.listen_port, 7500);
        assert!(c.pinned_hosts.contains_key("listen:7500") && !c.pinned_hosts.contains_key("listen:7420"));
        assert!(c.last_display.contains_key("listen:7500"));
        assert!(c.pinned_hosts.contains_key("studio.local:7420"));
    }

    #[test]
    fn accept_incoming_follows_the_active_connection() {
        let mut c = Config { host: Some("studio.local".into()), ..Config::default() };
        assert!(crate::connections::sync_from_host(&mut c));
        let s = Settings::from_config(&c, false);
        assert!(s.accept_incoming);
        apply(&mut c, &s, &Settings { accept_incoming: false, ..s.clone() });
        assert!(!c.accept_incoming);
        assert!(!crate::connections::active(&c).unwrap().accept_incoming);
        // Already in sync: a reload changes nothing.
        assert!(!crate::connections::sync_from_host(&mut c));
    }

    #[test]
    fn forget_displays_and_reset() {
        let mut c = base();
        c.last_display.insert("listen:7420".into(), Default::default());
        c.hud = true;
        c.mode = Some("sharp".into());
        c.allowed_peers = vec!["192.168.1.50".into()];
        let s = Settings::from_config(&c, true);
        assert_eq!(s.remembered_displays, 1);
        let r = s.reset();
        assert!(!r.hud && r.mode.is_none() && r.autostart);
        assert_eq!(r.allowed_peers, s.allowed_peers);
        assert_eq!(r.paired, s.paired);
        assert_eq!(r.remembered_displays, 1);
        apply(&mut c, &s, &Settings { remembered_displays: 0, ..s.clone() });
        assert!(c.last_display.is_empty());
    }

    #[test]
    fn text_dump_mentions_every_page() {
        let d = Draft::from_settings(&Settings::from_config(&base(), false));
        let t = to_text(&d, true);
        for p in Page::ALL.iter().filter(|p| **p != Page::Advanced) {
            assert!(t.contains(&format!("[{}]", p.title())), "{t}");
        }
        assert!(t.contains("mode: Automatic"));
        assert!(t.contains("listen port: 7420"));
    }
}
