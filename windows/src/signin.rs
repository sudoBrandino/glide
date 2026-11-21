//! Start at sign-in without connecting. Platform independent (unit-tested on macOS); the registry
//! and shortcut I/O live in `win::setup`.
//!
//! Windows starts the viewer at sign-in through the HKCU Run value (`setup::RUN_VALUE`, written by
//! the setup dialog and install.ps1), or an older install.ps1's Startup folder shortcut. Both pass
//! [`STARTUP_FLAG`]. With it, and config `connect_at_signin` off (the default), the viewer opens
//! paused: window and tray icon up, no dialing, no listening, until the user clicks Connect.
//! Launches by hand (Start menu, double-click, a CLI target) never carry the flag and connect.
//!
//! Entries written before the flag existed are rewritten with it ([`migrate_run_value`],
//! [`migrate_shortcut_args`]), but only when they start this very exe: an older copy elsewhere
//! would reject the unknown option and not start at all.

use std::path::Path;

/// The argument the sign-in entries pass.
pub const STARTUP_FLAG: &str = "--startup";

/// Open paused (Disconnected) instead of connecting.
pub fn start_paused(startup_launch: bool, connect_at_signin: bool) -> bool {
    startup_launch && !connect_at_signin
}

/// Does a command-line argument string carry [`STARTUP_FLAG`] (as a whole word)?
pub fn has_startup_flag(args: &str) -> bool {
    args.split_whitespace().any(|a| a.trim_matches('"').eq_ignore_ascii_case(STARTUP_FLAG))
}

/// Split a Run value into (exe, rest of the arguments). Accepts a quoted exe (what Glide writes)
/// or an unquoted path ending in `.exe` (a hand-made entry, possibly with spaces in the path).
pub fn split_run_value(value: &str) -> Option<(String, String)> {
    let v = value.trim();
    if let Some(rest) = v.strip_prefix('"') {
        let end = rest.find('"')?;
        let exe = &rest[..end];
        return (!exe.trim().is_empty()).then(|| (exe.to_string(), rest[end + 1..].trim().to_string()));
    }
    let lower = v.to_ascii_lowercase();
    // The first ".exe" that ends the path (followed by the end or a space).
    let mut from = 0;
    while let Some(i) = lower[from..].find(".exe") {
        let end = from + i + 4;
        if end == v.len() || v[end..].starts_with(char::is_whitespace) {
            return Some((v[..end].to_string(), v[end..].trim().to_string()));
        }
        from = end;
    }
    None
}

/// A Run value that starts `exe` without [`STARTUP_FLAG`]: the same value with the flag added
/// (other arguments kept). None = leave it alone (already has it, unreadable, or another exe).
pub fn migrate_run_value(value: &str, exe: &Path) -> Option<String> {
    let (target, args) = split_run_value(value)?;
    if !crate::setup::same_path(Path::new(&target), exe) || has_startup_flag(&args) {
        return None;
    }
    Some(if args.is_empty() { format!("\"{target}\" {STARTUP_FLAG}") } else { format!("\"{target}\" {args} {STARTUP_FLAG}") })
}

/// The Startup folder shortcut's arguments with [`STARTUP_FLAG`] added, if it points at `exe`
/// and doesn't have it yet. None = leave it alone.
pub fn migrate_shortcut_args(target: &Path, args: &str, exe: &Path) -> Option<String> {
    if !crate::setup::same_path(target, exe) || has_startup_flag(args) {
        return None;
    }
    let a = args.trim();
    Some(if a.is_empty() { STARTUP_FLAG.to_string() } else { format!("{a} {STARTUP_FLAG}") })
}

/// Whom the viewer connects to, for the paused status line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PausedTarget<'a> {
    /// Dials the Mac (and maybe also listens): its saved name or address.
    Mac(&'a str),
    /// Only listens for the Mac on this port.
    Listen(u16),
}

/// The window's status overlay while paused: that it isn't connected, and how to connect.
pub fn paused_status(t: PausedTarget) -> String {
    let first = match t {
        PausedTarget::Mac(name) if !name.trim().is_empty() => {
            format!("Not connected — press Enter or click here to connect to {}", name.trim())
        }
        PausedTarget::Mac(_) => "Not connected — press Enter or click here to connect".to_string(),
        PausedTarget::Listen(port) => format!("Not connected — press Enter or click here to let the Mac connect (port {port})"),
    };
    format!("{first}\nOther Macs: Connections… in the Glide menu (Ctrl+Alt+Shift+Space) or the tray icon")
}

/// The name for [`PausedTarget::Mac`]: the active saved connection's name when the target came
/// from the config, else the address being dialed.
pub fn connect_label(c: &crate::config::Config, cli_target: bool, addr: &str) -> String {
    if !cli_target {
        if let Some(s) = crate::connections::active(c) {
            if !s.name.trim().is_empty() {
                return s.name.clone();
            }
        }
    }
    addr.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "C:\\Users\\me\\AppData\\Local\\Glide\\glide-client.exe";

    #[test]
    fn paused_only_for_signin_launches() {
        assert!(start_paused(true, false), "sign-in, default config: paused");
        assert!(!start_paused(true, true), "sign-in, connect_at_signin: connects");
        assert!(!start_paused(false, false), "by hand: connects");
        assert!(!start_paused(false, true));
    }

    #[test]
    fn flag_detection() {
        assert!(has_startup_flag("--startup"));
        assert!(has_startup_flag("mac.local --startup"));
        assert!(has_startup_flag("  --STARTUP "));
        assert!(!has_startup_flag(""));
        assert!(!has_startup_flag("--startups"));
        assert!(!has_startup_flag("--setup"));
    }

    #[test]
    fn run_value_split() {
        assert_eq!(split_run_value(&format!("\"{EXE}\"")), Some((EXE.into(), "".into())));
        assert_eq!(split_run_value(&format!("\"{EXE}\" --startup")), Some((EXE.into(), "--startup".into())));
        assert_eq!(split_run_value("C:\\Program Files\\Glide\\glide-client.exe"), Some(("C:\\Program Files\\Glide\\glide-client.exe".into(), "".into())));
        assert_eq!(split_run_value("C:\\a.exe.d\\g.exe mac.local"), Some(("C:\\a.exe.d\\g.exe".into(), "mac.local".into())));
        assert_eq!(split_run_value("\"unterminated"), None);
        assert_eq!(split_run_value("\"\" x"), None);
        assert_eq!(split_run_value("notepad"), None);
    }

    #[test]
    fn run_value_migration() {
        let exe = Path::new(EXE);
        // Written by the setup dialog / install.ps1 before the flag existed.
        assert_eq!(migrate_run_value(&format!("\"{EXE}\""), exe), Some(format!("\"{EXE}\" --startup")));
        // Case and separators don't matter; other arguments are kept.
        let odd = "\"c:/users/me/appdata/local/glide/GLIDE-CLIENT.EXE\" --no-audio";
        assert_eq!(migrate_run_value(odd, exe), Some("\"c:/users/me/appdata/local/glide/GLIDE-CLIENT.EXE\" --no-audio --startup".into()));
        // Unquoted.
        assert_eq!(migrate_run_value(EXE, exe), Some(format!("\"{EXE}\" --startup")));
        // Already migrated: nothing to do (also what `setup::run_value` writes now).
        assert_eq!(migrate_run_value(&format!("\"{EXE}\" --startup"), exe), None);
        assert_eq!(migrate_run_value(&crate::setup::run_value(exe), exe), None);
        // Another copy (may be an older version that would reject --startup): left alone.
        assert_eq!(migrate_run_value("\"C:\\Users\\me\\Downloads\\glide-client.exe\"", exe), None);
        assert_eq!(migrate_run_value("garbage", exe), None);
    }

    #[test]
    fn shortcut_migration() {
        let exe = Path::new(EXE);
        assert_eq!(migrate_shortcut_args(exe, "", exe), Some("--startup".into()));
        assert_eq!(migrate_shortcut_args(exe, " 192.168.1.50 ", exe), Some("192.168.1.50 --startup".into()), "an old install.ps1 put the Mac there");
        assert_eq!(migrate_shortcut_args(exe, "--listen --startup", exe), None);
        assert_eq!(migrate_shortcut_args(Path::new("C:\\Other\\glide-client.exe"), "", exe), None);
    }

    #[test]
    fn paused_text() {
        let s = paused_status(PausedTarget::Mac("Studio Mac"));
        assert!(s.starts_with("Not connected — press Enter or click here to connect to Studio Mac\n"), "{s}");
        assert!(s.contains("Connections…"), "{s}");
        assert!(paused_status(PausedTarget::Mac("  ")).starts_with("Not connected — press Enter or click here to connect\n"));
        assert!(paused_status(PausedTarget::Listen(7420)).contains("let the Mac connect (port 7420)"));
    }

    #[test]
    fn label_prefers_saved_name() {
        use crate::connections::{add, Draft};
        let mut c = crate::config::Config::default();
        assert_eq!(connect_label(&c, false, "192.168.1.20"), "192.168.1.20");
        add(&mut c, &Draft { name: "Studio Mac".into(), address: "192.168.1.20".into(), ..Draft::new_default() }).unwrap();
        assert_eq!(connect_label(&c, false, "192.168.1.20"), "Studio Mac");
        assert_eq!(connect_label(&c, true, "10.0.0.5"), "10.0.0.5", "a host on the command line isn't the saved one");
    }
}
