//! Managed configuration (docs/ENTERPRISE.md §11.2): what the organization's MDM / Group Policy
//! sets. On Windows: `HKLM\SOFTWARE\Policies\Glide`, then `HKCU\SOFTWARE\Policies\Glide`, values
//! `CloudURL` (REG_SZ), `EnrollmentToken` (REG_SZ), `DeviceName` (REG_SZ), `Tags` (REG_MULTI_SZ),
//! `DisableLANMode` (REG_DWORD). Elsewhere (tests) a `MapSource` stands in for the registry.
//!
//! Precedence: machine policy is authoritative. The enrollment values (`CloudURL`,
//! `EnrollmentToken`, `DeviceName`, `Tags`) come as one set from the first scope that has a
//! `CloudURL`, so a user-policy value can never be mixed into a machine-policy enrollment (e.g. a
//! different token for the machine's tenant). `DisableLANMode` is set if either scope sets it: a
//! local override may only be stricter.

use std::collections::HashMap;

/// One policy scope (a registry key, or a map in tests).
pub trait PolicySource {
    fn string(&self, name: &str) -> Option<String>;
    fn multi_string(&self, name: &str) -> Option<Vec<String>>;
    fn dword(&self, name: &str) -> Option<u32>;
}

/// In-memory policy scope (tests, and non-Windows builds that inject a configuration).
#[derive(Default, Clone, Debug)]
pub struct MapSource {
    pub strings: HashMap<String, String>,
    pub multi: HashMap<String, Vec<String>>,
    pub dwords: HashMap<String, u32>,
}

impl MapSource {
    pub fn with(mut self, name: &str, value: &str) -> Self {
        self.strings.insert(name.into(), value.into());
        self
    }
    pub fn with_multi(mut self, name: &str, v: &[&str]) -> Self {
        self.multi.insert(name.into(), v.iter().map(|s| s.to_string()).collect());
        self
    }
    pub fn with_dword(mut self, name: &str, v: u32) -> Self {
        self.dwords.insert(name.into(), v);
        self
    }
}

impl PolicySource for MapSource {
    fn string(&self, name: &str) -> Option<String> {
        self.strings.get(name).cloned()
    }
    fn multi_string(&self, name: &str) -> Option<Vec<String>> {
        self.multi.get(name).cloned()
    }
    fn dword(&self, name: &str) -> Option<u32> {
        self.dwords.get(name).copied()
    }
}

/// The effective managed configuration.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ManagedConfig {
    /// Normalized: scheme + host[:port], no trailing slash or path.
    pub cloud_url: String,
    pub enrollment_token: Option<String>,
    pub device_name: Option<String>,
    pub tags: Vec<String>,
    pub disable_lan_mode: bool,
}

/// Parsed `scheme://host[:port]` of a cloud or relay URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Url {
    /// "https", "http", "wss" or "ws".
    pub scheme: String,
    /// Lowercase host (IPv6 without brackets).
    pub host: String,
    pub port: u16,
    /// Path and query, starting with '/' ("/" when empty).
    pub path: String,
}

impl Url {
    pub fn parse(s: &str) -> Result<Url, String> {
        let s = s.trim();
        let (scheme, rest) = s.split_once("://").ok_or_else(|| format!("{s:?} is not a URL"))?;
        let scheme = scheme.to_ascii_lowercase();
        let default_port = match scheme.as_str() {
            "https" | "wss" => 443,
            "http" | "ws" => 80,
            _ => return Err(format!("unsupported URL scheme {scheme:?}")),
        };
        let (authority, path) = match rest.find(['/', '?', '#']) {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, ""),
        };
        if authority.contains('@') {
            return Err("URLs with user information are not allowed".into());
        }
        let (host, port) = if let Some(r) = authority.strip_prefix('[') {
            let (h, after) = r.split_once(']').ok_or("bad IPv6 address in URL")?;
            let port = match after.strip_prefix(':') {
                Some(p) => p.parse().map_err(|_| "bad port in URL")?,
                None if after.is_empty() => default_port,
                None => return Err("bad URL authority".into()),
            };
            (h.to_string(), port)
        } else {
            match authority.rsplit_once(':') {
                Some((h, p)) => (h.to_string(), p.parse().map_err(|_| "bad port in URL")?),
                None => (authority.to_string(), default_port),
            }
        };
        if host.is_empty() || host.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err("missing or invalid host in URL".into());
        }
        let path = path.split('#').next().unwrap_or("");
        let path = if path.is_empty() { "/".to_string() } else if path.starts_with('?') { format!("/{path}") } else { path.to_string() };
        Ok(Url { scheme, host: host.to_ascii_lowercase(), port, path })
    }

    pub fn secure(&self) -> bool {
        matches!(self.scheme.as_str(), "https" | "wss")
    }

    pub fn is_loopback(&self) -> bool {
        self.host == "localhost" || self.is_loopback_ip()
    }

    /// The host is a loopback IP address (`127.0.0.0/8`, `::1`), not a name.
    pub fn is_loopback_ip(&self) -> bool {
        self.host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
    }

    /// `scheme://host[:port]` (default port omitted).
    pub fn origin(&self) -> String {
        let default = if self.secure() { 443 } else { 80 };
        let host = if self.host.contains(':') { format!("[{}]", self.host) } else { self.host.clone() };
        if self.port == default {
            format!("{}://{host}", self.scheme)
        } else {
            format!("{}://{host}:{}", self.scheme, self.port)
        }
    }
}

/// Validates and normalizes `CloudURL` (docs/ENTERPRISE.md §6.7): an origin, `https://host[:port]`
/// with no user info, path, query or fragment (a lone `/` is allowed). Plain `http` only when the
/// host is a loopback IP address (`127.0.0.0/8`, `::1`), for a local development service.
pub fn normalize_cloud_url(s: &str) -> Result<String, String> {
    let s = s.trim();
    let u = Url::parse(s)?;
    let rest = s.split_once("://").map(|(_, r)| r).unwrap_or("");
    let tail = rest.find(['/', '?', '#']).map(|i| &rest[i..]).unwrap_or("");
    if !tail.is_empty() && tail != "/" {
        return Err(format!("CloudURL must be an origin like https://glide.example.com, without a path, query or fragment (got {s:?})"));
    }
    match u.scheme.as_str() {
        "https" => {}
        "http" if u.is_loopback_ip() => {}
        "http" => return Err("CloudURL must use https:// (plain http only to a loopback IP address)".into()),
        _ => return Err("CloudURL must be an https:// URL".into()),
    }
    Ok(u.origin())
}

/// May the viewer open `url` in the browser (§6.7)? Only `https` URLs on the CloudURL's host and
/// port, without whitespace or control characters.
pub fn browser_url_allowed(cloud_url: &str, url: &str) -> bool {
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    match (Url::parse(cloud_url), Url::parse(url)) {
        (Ok(c), Ok(u)) => u.scheme == "https" && u.host == c.host && u.port == c.port,
        _ => false,
    }
}

fn non_empty(s: Option<String>) -> Option<String> {
    s.map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// Reads the managed configuration from `scopes` in precedence order (machine policy first).
/// `Ok(None)`: not managed (no scope has a `CloudURL`, and none disables LAN mode).
/// `Err`: a `CloudURL` is set but invalid (logged; the app runs unmanaged).
pub fn read(scopes: &[&dyn PolicySource]) -> Result<Option<ManagedConfig>, String> {
    let disable_lan_mode = scopes.iter().any(|s| s.dword("DisableLANMode").is_some_and(|v| v != 0));
    let Some(src) = scopes.iter().find(|s| non_empty(s.string("CloudURL")).is_some()) else {
        return Ok(disable_lan_mode.then(|| ManagedConfig { disable_lan_mode, ..Default::default() }));
    };
    let cloud_url = normalize_cloud_url(&non_empty(src.string("CloudURL")).unwrap_or_default())?;
    let mut tags: Vec<String> = src.multi_string("Tags").unwrap_or_default().into_iter().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect();
    tags.dedup();
    Ok(Some(ManagedConfig {
        cloud_url,
        enrollment_token: non_empty(src.string("EnrollmentToken")),
        device_name: non_empty(src.string("DeviceName")).map(|n| super::api::clean_display(&n).chars().take(64).collect()).filter(|n: &String| !n.is_empty()),
        tags,
        disable_lan_mode,
    }))
}

impl ManagedConfig {
    /// A cloud is configured (not just `DisableLANMode`).
    pub fn has_cloud(&self) -> bool {
        !self.cloud_url.is_empty()
    }
}

/// The registry scopes (Windows).
#[cfg(windows)]
pub mod registry {
    use super::PolicySource;
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::*;

    pub const KEY: &str = "SOFTWARE\\Policies\\Glide";

    pub struct RegSource {
        root: HKEY,
        key: &'static str,
    }

    impl RegSource {
        pub fn machine() -> RegSource {
            RegSource { root: HKEY_LOCAL_MACHINE, key: KEY }
        }
        pub fn user() -> RegSource {
            RegSource { root: HKEY_CURRENT_USER, key: KEY }
        }
        /// Any key under HKLM (e.g. the OS version).
        pub fn hklm(key: &'static str) -> RegSource {
            RegSource { root: HKEY_LOCAL_MACHINE, key }
        }
        /// The policy key exists in machine policy (the organization deploys Glide).
        pub fn machine_policy_exists() -> bool {
            let key: Vec<u16> = KEY.encode_utf16().chain(Some(0)).collect();
            let mut h = HKEY::default();
            unsafe {
                let ok = RegOpenKeyExW(HKEY_LOCAL_MACHINE, PCWSTR(key.as_ptr()), Some(0), KEY_READ, &mut h) == windows::Win32::Foundation::ERROR_SUCCESS;
                if ok {
                    let _ = RegCloseKey(h);
                }
                ok
            }
        }

        fn raw(&self, name: &str, want: REG_VALUE_TYPE) -> Option<Vec<u8>> {
            let key: Vec<u16> = self.key.encode_utf16().chain(Some(0)).collect();
            let val: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
            unsafe {
                let mut size = 0u32;
                let mut ty = REG_VALUE_TYPE(0);
                let flags = RRF_RT_ANY;
                if RegGetValueW(self.root, PCWSTR(key.as_ptr()), PCWSTR(val.as_ptr()), flags, Some(&mut ty as *mut _), None, Some(&mut size as *mut _)) != windows::Win32::Foundation::ERROR_SUCCESS {
                    return None;
                }
                if ty != want || size == 0 || size > 1 << 16 {
                    return None;
                }
                let mut buf = vec![0u8; size as usize];
                if RegGetValueW(self.root, PCWSTR(key.as_ptr()), PCWSTR(val.as_ptr()), flags, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut size as *mut _))
                    != windows::Win32::Foundation::ERROR_SUCCESS
                {
                    return None;
                }
                buf.truncate(size as usize);
                Some(buf)
            }
        }
    }

    fn utf16(b: &[u8]) -> Vec<u16> {
        b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    }

    impl PolicySource for RegSource {
        fn string(&self, name: &str) -> Option<String> {
            let w = utf16(&self.raw(name, REG_SZ)?);
            let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
            Some(String::from_utf16_lossy(&w[..end]))
        }
        fn multi_string(&self, name: &str) -> Option<Vec<String>> {
            let w = utf16(&self.raw(name, REG_MULTI_SZ)?);
            Some(w.split(|&c| c == 0).filter(|s| !s.is_empty()).map(String::from_utf16_lossy).collect())
        }
        fn dword(&self, name: &str) -> Option<u32> {
            let b = self.raw(name, REG_DWORD)?;
            (b.len() >= 4).then(|| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        }
    }
}

/// The managed configuration of this machine (registry on Windows; never managed elsewhere).
pub fn load() -> Result<Option<ManagedConfig>, String> {
    #[cfg(windows)]
    {
        let (m, u) = (registry::RegSource::machine(), registry::RegSource::user());
        read(&[&m, &u])
    }
    #[cfg(not(windows))]
    {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_managed() {
        assert_eq!(read(&[&MapSource::default(), &MapSource::default()]), Ok(None));
        assert_eq!(read(&[]), Ok(None));
    }

    #[test]
    fn machine_policy() {
        let m = MapSource::default()
            .with("CloudURL", " https://Glide.Example.com/ ")
            .with("EnrollmentToken", "enr_secret")
            .with("DeviceName", "Front desk")
            .with_multi("Tags", &["staff-macs", " ", "lobby"]);
        let c = read(&[&m, &MapSource::default()]).unwrap().unwrap();
        assert_eq!(c.cloud_url, "https://glide.example.com");
        assert_eq!(c.enrollment_token.as_deref(), Some("enr_secret"));
        assert_eq!(c.device_name.as_deref(), Some("Front desk"));
        assert_eq!(c.tags, vec!["staff-macs", "lobby"]);
        assert!(!c.disable_lan_mode && c.has_cloud());
    }

    #[test]
    fn machine_wins_and_scopes_never_mix() {
        let m = MapSource::default().with("CloudURL", "https://machine.example.com").with("EnrollmentToken", "enr_m");
        let u = MapSource::default().with("CloudURL", "https://user.example.com").with("EnrollmentToken", "enr_u").with("DeviceName", "mine");
        let c = read(&[&m, &u]).unwrap().unwrap();
        assert_eq!((c.cloud_url.as_str(), c.enrollment_token.as_deref(), c.device_name.as_deref()), ("https://machine.example.com", Some("enr_m"), None));
        // A machine token without a URL doesn't borrow the user's URL.
        let m = MapSource::default().with("EnrollmentToken", "enr_m");
        let c = read(&[&m, &u]).unwrap().unwrap();
        assert_eq!((c.cloud_url.as_str(), c.enrollment_token.as_deref()), ("https://user.example.com", Some("enr_u")));
    }

    #[test]
    fn disable_lan_mode_is_stricter_of_both() {
        let m = MapSource::default().with("CloudURL", "https://c.example.com").with_dword("DisableLANMode", 0);
        let u = MapSource::default().with_dword("DisableLANMode", 1);
        assert!(read(&[&m, &u]).unwrap().unwrap().disable_lan_mode);
        // DisableLANMode alone: "managed" only in that LAN mode is off.
        let c = read(&[&MapSource::default().with_dword("DisableLANMode", 1)]).unwrap().unwrap();
        assert!(c.disable_lan_mode && !c.has_cloud());
    }

    #[test]
    fn cloud_url_rules() {
        assert_eq!(normalize_cloud_url("https://glide.example.com:8443"), Ok("https://glide.example.com:8443".into()));
        assert_eq!(normalize_cloud_url("https://glide.example.com:443"), Ok("https://glide.example.com".into()));
        assert_eq!(normalize_cloud_url("HTTPS://Glide.Example.com/"), Ok("https://glide.example.com".into()), "a lone / is fine");
        assert_eq!(normalize_cloud_url("http://127.0.0.1:8787"), Ok("http://127.0.0.1:8787".into()));
        assert_eq!(normalize_cloud_url("http://127.1.2.3:8787/"), Ok("http://127.1.2.3:8787".into()));
        assert_eq!(normalize_cloud_url("http://[::1]:8787"), Ok("http://[::1]:8787".into()));
        assert_eq!(normalize_cloud_url("https://[::1]:9000"), Ok("https://[::1]:9000".into()));
        // An origin only: no path, query or fragment.
        for bad in [
            "https://glide.example.com/console",
            "https://glide.example.com/console/",
            "https://glide.example.com:8443/x?y",
            "https://glide.example.com?x=1",
            "https://glide.example.com/?x",
            "https://glide.example.com#top",
            "https://glide.example.com/#",
            "https://glide.example.com//",
        ] {
            assert!(normalize_cloud_url(bad).is_err(), "{bad}");
        }
        assert!(read(&[&MapSource::default().with("CloudURL", "https://glide.example.com/tenant")]).is_err());
        // Plain http only to a loopback IP address (not a name).
        assert!(normalize_cloud_url("http://localhost:8787").is_err());
        assert!(normalize_cloud_url("http://10.0.0.1").is_err());
        assert!(normalize_cloud_url("http://glide.example.com").is_err());
        assert!(normalize_cloud_url("ftp://glide.example.com").is_err());
        assert!(normalize_cloud_url("https://user:pw@glide.example.com").is_err());
        assert!(normalize_cloud_url("glide.example.com").is_err());
        assert!(normalize_cloud_url("https://").is_err());
        assert!(read(&[&MapSource::default().with("CloudURL", "http://evil.example.com")]).is_err());
    }

    #[test]
    fn browser_urls() {
        let c = "https://glide.example.com";
        assert!(browser_url_allowed(c, "https://glide.example.com/auth/device?user_code=ABCD-EFGH"));
        assert!(browser_url_allowed(c, "https://Glide.Example.com:443/auth/device"));
        assert!(!browser_url_allowed(c, "http://glide.example.com/auth/device"), "https only");
        assert!(!browser_url_allowed(c, "https://glide.example.com:8443/auth/device"), "same port");
        assert!(!browser_url_allowed(c, "https://evil.example.com/auth/device"));
        assert!(!browser_url_allowed(c, "https://glide.example.com.evil.example/auth"));
        assert!(!browser_url_allowed(c, "https://user@glide.example.com/"));
        assert!(!browser_url_allowed(c, "file:///C:/Windows/System32/calc.exe"));
        assert!(!browser_url_allowed(c, "https://glide.example.com/a b"));
        assert!(!browser_url_allowed(c, "https://glide.example.com/\u{0}"));
        assert!(browser_url_allowed("https://glide.example.com:8443", "https://glide.example.com:8443/auth/device"));
        // A loopback development cloud on plain http: its pages aren't opened (shown only).
        assert!(!browser_url_allowed("http://127.0.0.1:8787", "http://127.0.0.1:8787/auth/device"));
    }

    #[test]
    fn url_parts() {
        let u = Url::parse("wss://Glide.example.com/v1/relay/ses_1?ticket=a.b").unwrap();
        assert_eq!((u.scheme.as_str(), u.host.as_str(), u.port, u.path.as_str()), ("wss", "glide.example.com", 443, "/v1/relay/ses_1?ticket=a.b"));
        assert_eq!(Url::parse("http://h:81").unwrap().path, "/");
        assert!(Url::parse("https://h:x").is_err());
    }
}
