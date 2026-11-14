//! Setup logic shared by the setup dialog (`win::setup`), kept platform independent so it is
//! unit-tested on macOS: where the viewer installs, whether to offer installing, the Mac address
//! check, this PC's address as the Mac sees it, and the PowerShell the firewall step runs.

use std::net::{SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Start Menu shortcut name (the same one install.ps1 creates).
pub const SHORTCUT_NAME: &str = "Glide Viewer.lnk";
/// Firewall rule display name (the same one install.ps1 creates).
pub const FIREWALL_RULE: &str = "Glide Viewer";
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run value name.
pub const RUN_VALUE: &str = "Glide Viewer";
/// Files copied next to the exe when installing, if present beside it.
pub const EXTRA_FILES: [&str; 2] = ["README.txt", "LICENSE.txt"];

/// `%LOCALAPPDATA%\Glide`, the default install folder.
pub fn default_install_dir(env: impl Fn(&str) -> Option<String>) -> Option<PathBuf> {
    env("LOCALAPPDATA").filter(|s| !s.is_empty()).map(|d| PathBuf::from(d).join("Glide"))
}

/// Case-insensitive path comparison that ignores a `\\?\` prefix, `/` vs `\` and trailing
/// separators (Windows paths; good enough for "is this the same file/folder").
pub fn same_path(a: &Path, b: &Path) -> bool {
    fn norm(p: &Path) -> String {
        let s = p.to_string_lossy().replace('/', "\\");
        let s = s.strip_prefix("\\\\?\\").unwrap_or(&s);
        s.trim_end_matches('\\').to_lowercase()
    }
    norm(a) == norm(b)
}

/// Offer to install when the exe isn't in the install folder, and the user hasn't chosen to run
/// this exe as is before (config `portable_exe`).
pub fn offer_install(exe: &Path, install_dir: &Path, portable_exe: Option<&str>) -> bool {
    // Split on both separators by hand: Path only knows `\\` on Windows (and this is tested on macOS).
    let e = exe.to_string_lossy();
    let in_dir = e.rfind(['\\', '/']).is_some_and(|i| same_path(Path::new(&e[..i]), install_dir));
    let portable = portable_exe.is_some_and(|p| same_path(Path::new(p), exe));
    !in_dir && !portable
}

/// Check what the user typed as the Mac's address: a host name or IP, optional `:port`.
/// Returns the trimmed address (port kept as typed).
pub fn normalize_address(input: &str) -> Result<String, String> {
    let a = input.trim();
    if a.is_empty() {
        return Err("Enter the Mac's address (shown in its Glide setup window)".into());
    }
    if a.chars().any(|c| c.is_whitespace() || c == '/' || c == '\\') {
        return Err(format!("“{a}” is not an address: use the IP address or name of the Mac, e.g. 192.168.1.20"));
    }
    let addr = crate::net::parse_addr(a);
    if let Some((_, port)) = addr.rsplit_once(':') {
        if port.parse::<u16>().ok().filter(|p| *p != 0).is_none() {
            return Err(format!("“{a}” has a bad port number"));
        }
    }
    Ok(a.to_string())
}

/// TCP connect test (no handshake): can this PC reach the Mac's Glide port?
pub fn test_reachable(addr: &str, timeout: Duration) -> Result<SocketAddr, String> {
    let a = crate::net::parse_addr(addr);
    let sa = a.to_socket_addrs().map_err(|_| format!("can't find {addr}"))?.next().ok_or_else(|| format!("can't find {addr}"))?;
    TcpStream::connect_timeout(&sa, timeout).map(|_| sa).map_err(|e| e.to_string())
}

/// This PC's IPv4 address on the interface that leads toward `toward` (the Mac, or any routable
/// address): what the Mac should dial. A UDP "connect" picks the route without sending anything.
pub fn local_ipv4_toward(toward: Option<&str>) -> Option<std::net::Ipv4Addr> {
    let target = toward
        .and_then(|t| crate::net::parse_addr(t).to_socket_addrs().ok()?.find(|a| a.is_ipv4()))
        .unwrap_or_else(|| SocketAddr::from(([10, 255, 255, 255], 9)));
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect(target).ok()?;
    match s.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(v4) if !v4.is_unspecified() && !v4.is_loopback() => Some(v4),
        _ => None,
    }
}

/// `'...'` PowerShell literal.
pub fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// `powershell -EncodedCommand` argument: base64 of the UTF-16LE script (no quoting issues).
pub fn ps_encode(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    base64(&bytes)
}

fn base64(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Read-only firewall check (runs unelevated): enabled inbound Allow / Block rules for `exe`, and
/// whether a connected network is Public (a Private/Domain rule doesn't apply there).
/// Prints one line: `allow=N block=N public=0|1`.
pub fn firewall_check_script(exe: &str) -> String {
    format!(
        "$p={}; $r=@(Get-NetFirewallApplicationFilter -Program $p -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {{ $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' }}); \
         $pub=@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object {{ $_.NetworkCategory -eq 'Public' }}).Count; \
         \"allow=$(@($r | Where-Object {{ $_.Action -eq 'Allow' }}).Count) block=$(@($r | Where-Object {{ $_.Action -eq 'Block' }}).Count) public=$([int]($pub -gt 0))\"",
        ps_quote(exe)
    )
}

/// The elevated firewall step: remove inbound Block rules for `exe` (Windows adds one when
/// someone clicks Cancel on its own prompt) and any old "Glide Viewer" rule, then allow inbound
/// TCP `port` for `exe` on Private and Domain networks.
pub fn firewall_allow_script(exe: &str, port: u16) -> String {
    format!(
        "$p={}; Get-NetFirewallApplicationFilter -Program $p -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {{ $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' }} | Remove-NetFirewallRule; \
         Get-NetFirewallRule -DisplayName {} -ErrorAction SilentlyContinue | Remove-NetFirewallRule; \
         New-NetFirewallRule -DisplayName {} -Direction Inbound -Program $p -Protocol TCP -LocalPort {port} -Profile Private,Domain -Action Allow | Out-Null",
        ps_quote(exe),
        ps_quote(FIREWALL_RULE),
        ps_quote(FIREWALL_RULE)
    )
}

/// Result of `firewall_check_script`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FirewallStatus {
    pub allow: u32,
    pub block: u32,
    /// A connected network is set to Public.
    pub public: bool,
}

impl FirewallStatus {
    pub fn parse(out: &str) -> Option<FirewallStatus> {
        let line = out.lines().rev().find(|l| l.trim_start().starts_with("allow="))?;
        let mut st = FirewallStatus::default();
        for kv in line.split_whitespace() {
            let (k, v) = kv.split_once('=')?;
            let n: u32 = v.parse().ok()?;
            match k {
                "allow" => st.allow = n,
                "block" => st.block = n,
                "public" => st.public = n != 0,
                _ => {}
            }
        }
        Some(st)
    }

    /// The Mac can connect (as far as the firewall goes): an Allow rule and no Block rule
    /// (Block wins in Windows Firewall).
    pub fn ok(&self) -> bool {
        self.allow > 0 && self.block == 0
    }

    /// One line for the setup dialog.
    pub fn describe(&self) -> String {
        let base = if self.block > 0 {
            "Windows Firewall blocks Glide: click Allow to fix it."
        } else if self.allow > 0 {
            "Windows Firewall allows Glide."
        } else {
            "Windows Firewall will block the Mac until you click Allow."
        };
        if self.public {
            format!("{base} This network is set to Public, where Windows blocks it anyway: set it to Private in Settings → Network.")
        } else {
            base.to_string()
        }
    }
}

/// The value stored under the Run key: the quoted exe path.
pub fn run_value(exe: &Path) -> String {
    format!("\"{}\"", exe.display())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_paths() {
        let env = |k: &str| (k == "LOCALAPPDATA").then(|| "C:\\Users\\b\\AppData\\Local".to_string());
        let dir = default_install_dir(env).unwrap();
        assert_eq!(dir, PathBuf::from("C:\\Users\\b\\AppData\\Local").join("Glide"));
        assert_eq!(default_install_dir(|_| None), None);
        let installed = Path::new("C:\\Users\\b\\AppData\\Local\\Glide\\glide-client.exe");
        let inst_dir = Path::new("c:\\users\\b\\appdata\\local\\glide\\");
        assert!(!offer_install(installed, inst_dir, None), "already installed (case, trailing slash)");
        assert!(!offer_install(Path::new("\\\\?\\C:\\Users\\b\\AppData\\Local\\Glide\\glide-client.exe"), inst_dir, None));
        let dl = Path::new("C:\\Users\\b\\Downloads\\glide-client.exe");
        assert!(offer_install(dl, inst_dir, None));
        assert!(offer_install(dl, inst_dir, Some("C:\\Other\\glide-client.exe")));
        assert!(!offer_install(dl, inst_dir, Some("c:/users/b/downloads/glide-client.exe")), "chose to run it from there");
    }

    #[test]
    fn addresses() {
        assert_eq!(normalize_address("  10.0.99.4 ").unwrap(), "10.0.99.4");
        assert_eq!(normalize_address("mac.local:7421").unwrap(), "mac.local:7421");
        assert_eq!(normalize_address("fe80::1").unwrap(), "fe80::1");
        assert!(normalize_address("").is_err());
        assert!(normalize_address("my mac").is_err());
        assert!(normalize_address("http://mac").is_err());
        assert!(normalize_address("mac:99999").is_err());
        assert!(normalize_address("mac:0").is_err());
    }

    #[test]
    fn reachability_against_loopback() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        assert!(test_reachable(&format!("127.0.0.1:{port}"), Duration::from_secs(2)).is_ok());
        drop(l);
        assert!(test_reachable(&format!("127.0.0.1:{port}"), Duration::from_secs(2)).is_err());
    }

    #[test]
    fn base64_and_powershell() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        // UTF-16LE: "a" = 61 00
        assert_eq!(ps_encode("a"), "YQA=");
        assert_eq!(ps_quote("C:\\O'Brien\\glide.exe"), "'C:\\O''Brien\\glide.exe'");
        let s = firewall_allow_script("C:\\x\\glide-client.exe", 7420);
        assert!(s.starts_with("$p='C:\\x\\glide-client.exe';"));
        assert!(s.contains("-LocalPort 7420 -Profile Private,Domain -Action Allow"));
        assert!(s.contains("-DisplayName 'Glide Viewer'"));
        assert!(firewall_check_script("C:\\x.exe").contains("allow=$("));
    }

    #[test]
    fn firewall_status() {
        let st = FirewallStatus::parse("WARNING: x\r\nallow=1 block=0 public=0\r\n").unwrap();
        assert!(st.ok() && !st.public);
        let st = FirewallStatus::parse("allow=2 block=1 public=1").unwrap();
        assert!(!st.ok() && st.public);
        assert!(st.describe().contains("blocks") && st.describe().contains("Public"));
        assert!(!FirewallStatus::parse("allow=0 block=0 public=0").unwrap().ok());
        assert_eq!(FirewallStatus::parse("garbage"), None);
        assert_eq!(FirewallStatus::parse("allow=x"), None);
        assert_eq!(run_value(Path::new("C:\\a b\\g.exe")), "\"C:\\a b\\g.exe\"");
    }

    #[test]
    fn local_address_is_not_loopback() {
        // No network in some sandboxes: only check what comes back.
        if let Some(ip) = local_ipv4_toward(None) {
            assert!(!ip.is_loopback() && !ip.is_unspecified());
        }
    }
}
