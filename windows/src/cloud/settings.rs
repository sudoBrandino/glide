//! What the org settings (docs/ENTERPRISE.md §7) mean for this app, as pure functions.

use super::api::Settings;

/// The app may listen on and dial its LAN port. A local `DisableLANMode` only makes this stricter.
/// `settings` None = not enrolled (or no settings known yet): LAN mode as usual.
pub fn lan_allowed(settings: Option<&Settings>, local_disable: bool) -> bool {
    !local_disable && settings.is_none_or(|s| s.lan_mode)
}

/// The LAN pairing window may be opened (host) / a new LAN host may be paired (viewer).
pub fn local_pairing_allowed(settings: Option<&Settings>, local_disable: bool) -> bool {
    lan_allowed(settings, local_disable) && settings.is_none_or(|s| s.allow_local_pairing)
}

/// Dotted numeric version → components ("0.3.1" → [0, 3, 1]); a pre-release or build suffix
/// after '-' or '+' is ignored. None if a component isn't a number.
pub fn parse_version(v: &str) -> Option<Vec<u64>> {
    let core = v.trim().trim_start_matches('v').split(['-', '+']).next()?;
    if core.is_empty() {
        return None;
    }
    core.split('.').map(|p| p.parse::<u64>().ok()).collect()
}

/// This app (`app_version`) satisfies `min_app_version`. An unparsable minimum is treated as not
/// satisfied: the org asked for something this app can't prove it meets.
pub fn version_ok(app_version: &str, min: Option<&str>) -> bool {
    let Some(min) = min.map(str::trim).filter(|m| !m.is_empty()) else { return true };
    let (Some(mut a), Some(mut m)) = (parse_version(app_version), parse_version(min)) else { return false };
    let n = a.len().max(m.len());
    a.resize(n, 0);
    m.resize(n, 0);
    a >= m
}

/// This app's version.
pub fn app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// The user-facing line when the org requires a newer app.
pub fn update_required(min: &str) -> String {
    format!("Update required: your organization requires Glide {min} or later (this is {}). Managed sessions are refused until Glide is updated.", app_version())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(lan: bool, pair: bool) -> Settings {
        Settings { lan_mode: lan, allow_local_pairing: pair, ..Settings::default() }
    }

    #[test]
    fn lan_and_pairing() {
        assert!(lan_allowed(None, false));
        assert!(!lan_allowed(None, true));
        assert!(lan_allowed(Some(&s(true, true)), false));
        assert!(!lan_allowed(Some(&s(false, true)), false));
        assert!(!lan_allowed(Some(&s(true, true)), true), "the local override is stricter");
        assert!(local_pairing_allowed(Some(&s(true, true)), false));
        assert!(!local_pairing_allowed(Some(&s(true, false)), false));
        assert!(!local_pairing_allowed(Some(&s(false, true)), false), "no LAN, no LAN pairing");
        assert!(!local_pairing_allowed(None, true));
    }

    #[test]
    fn versions() {
        assert!(version_ok("0.3.1", None));
        assert!(version_ok("0.3.1", Some("")));
        assert!(version_ok("0.3.1", Some("0.3.1")));
        assert!(version_ok("0.3.1", Some("0.3")));
        assert!(version_ok("0.10.0", Some("0.9.9")));
        assert!(version_ok("1.0.0-beta", Some("1.0")));
        assert!(!version_ok("0.3.1", Some("0.3.2")));
        assert!(!version_ok("0.3.1", Some("1")));
        assert!(!version_ok("0.3.1", Some("latest")), "unparsable minimum: refuse");
        assert_eq!(parse_version("v1.2.3+abc"), Some(vec![1, 2, 3]));
        assert_eq!(parse_version("1..2"), None);
        assert!(update_required("9.0").contains("9.0"));
    }
}
