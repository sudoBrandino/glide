//! Saved connections: the Macs this viewer knows, managed in the Connections window (tray /
//! Glide menu → Connections…) and picked with `--connection NAME`.
//!
//! Platform independent so the model is unit-tested off Windows; `win::connections` is the UI.
//!
//! The running viewer still connects to exactly one target, resolved at startup from config
//! `host` / `accept_incoming` (`config::resolve_target`). The saved list sits on top of that:
//! the *active* connection is mirrored into `host` / `accept_incoming` (`activate`), so the
//! connect path, pairing pins (keyed by `pin_target`, i.e. by address) and an older viewer
//! reading the same file all keep working. `sync_from_host` goes the other way: a `host` written
//! by the Set up dialog, by hand, or by a viewer that predates this list becomes (or updates) a
//! saved connection, so the two never drift apart.
//!
//! `platform` names what is on the other end. This viewer connects to Glide hosts on Macs
//! (`PLATFORM_MAC`); other platforms are kept as-is in the file (so a newer viewer's entries survive a
//! round trip) but shown as unavailable and never activated.

use crate::config::{pin_fallback, pin_target, Config, TargetSpec};
use serde::{Deserialize, Serialize};

/// A Glide host on a Mac (the only platform this viewer can connect to).
pub const PLATFORM_MAC: &str = "mac";

/// Longest name / group accepted (characters).
pub const MAX_NAME: usize = 64;

/// One saved connection (config `connections`).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(default)]
pub struct SavedConnection {
    /// Stable id ("c1", "c2", …), referenced by `active_connection`.
    pub id: String,
    /// Display name ("Studio Mac").
    pub name: String,
    /// What the other end is (`PLATFORM_MAC`). Unknown platforms are kept but can't be used here.
    pub platform: String,
    /// The Mac's address, `HOST[:PORT]`. Empty = no address: wait for the Mac to connect to this
    /// PC (listen only).
    pub address: String,
    /// With an address: also listen, so the Mac can connect to this PC (one-way firewalls).
    pub accept_incoming: bool,
    /// Optional group ("Home", "Office"); the list is grouped by it.
    pub group: Option<String>,
    /// Pinned to the top of its group and of the tray's quick-connect list.
    pub favorite: bool,
    /// Last time a session with it started (RFC 3339 UTC).
    pub last_connected: Option<String>,
}

impl Default for SavedConnection {
    fn default() -> Self {
        SavedConnection {
            id: String::new(),
            name: String::new(),
            platform: PLATFORM_MAC.into(),
            address: String::new(),
            accept_incoming: true,
            group: None,
            favorite: false,
            last_connected: None,
        }
    }
}

impl SavedConnection {
    pub fn is_supported(&self) -> bool {
        self.platform == PLATFORM_MAC
    }
    /// The target this connection resolves to (same rules as `config::resolve_target`).
    pub fn target(&self, listen_port: u16) -> TargetSpec {
        let a = self.address.trim();
        if a.is_empty() {
            TargetSpec::Listen(listen_port)
        } else if self.accept_incoming {
            TargetSpec::Both { host: a.to_string(), port: listen_port }
        } else {
            TargetSpec::Connect(a.to_string())
        }
    }
    /// Pin-store key (`config::pin_target`) for this connection.
    pub fn pin_key(&self, listen_port: u16) -> String {
        pin_target(&self.target(listen_port))
    }
    /// The pinned host's name and pairing date, if this connection is paired.
    pub fn pairing<'a>(&self, c: &'a Config) -> Option<&'a crate::config::PinnedHost> {
        let t = self.target(c.listen_port);
        c.pin_entry(&pin_target(&t), pin_fallback(&t).as_deref()).map(|(_, p)| p)
    }
    /// "192.168.1.20" or "Waits for the Mac".
    pub fn address_label(&self) -> String {
        let a = self.address.trim();
        if a.is_empty() {
            "Waits for the Mac to connect".into()
        } else {
            a.to_string()
        }
    }
}

/// What the edit form produces (and what `validate` checks).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Draft {
    pub name: String,
    pub address: String,
    pub accept_incoming: bool,
    pub group: String,
    pub favorite: bool,
}

impl Draft {
    pub fn from_saved(s: &SavedConnection) -> Draft {
        Draft {
            name: s.name.clone(),
            address: s.address.clone(),
            accept_incoming: s.accept_incoming,
            group: s.group.clone().unwrap_or_default(),
            favorite: s.favorite,
        }
    }
    /// A new, empty draft (accepts incoming by default, like the Set up dialog).
    pub fn new_default() -> Draft {
        Draft { accept_incoming: true, ..Default::default() }
    }
}

/// A field the edit form should point at when `validate` fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    Name,
    Address,
    Group,
}

/// Check and clean up a draft. `editing` is the id being edited (excluded from the duplicate
/// name check). Returns the cleaned draft: trimmed, a blank name filled from the address.
pub fn validate(c: &Config, draft: &Draft, editing: Option<&str>) -> Result<Draft, (Field, String)> {
    let mut d = draft.clone();
    d.address = d.address.trim().to_string();
    if !d.address.is_empty() {
        d.address = crate::setup::normalize_address(&d.address).map_err(|e| (Field::Address, e))?;
    }
    d.name = collapse_ws(&d.name);
    if d.name.is_empty() {
        d.name = if d.address.is_empty() { "Mac (waits for it to connect)".to_string() } else { d.address.clone() };
    }
    if d.name.chars().count() > MAX_NAME {
        return Err((Field::Name, format!("Use a shorter name (at most {MAX_NAME} characters)")));
    }
    d.group = collapse_ws(&d.group);
    if d.group.chars().count() > MAX_NAME {
        return Err((Field::Group, format!("Use a shorter group name (at most {MAX_NAME} characters)")));
    }
    let clash = c.connections.iter().find(|s| Some(s.id.as_str()) != editing && s.name.to_lowercase() == d.name.to_lowercase());
    if let Some(s) = clash {
        return Err((Field::Name, format!("There is already a connection named “{}”", s.name)));
    }
    Ok(d)
}

fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn apply_draft(s: &mut SavedConnection, d: &Draft) {
    s.name = d.name.clone();
    s.address = d.address.clone();
    s.accept_incoming = d.accept_incoming;
    s.group = Some(d.group.clone()).filter(|g| !g.is_empty());
    s.favorite = d.favorite;
}

/// The next free id ("c1", "c2", …).
pub fn next_id(c: &Config) -> String {
    let n = c.connections.iter().filter_map(|s| s.id.strip_prefix('c')?.parse::<u64>().ok()).max().unwrap_or(0);
    format!("c{}", n + 1)
}

pub fn get<'a>(c: &'a Config, id: &str) -> Option<&'a SavedConnection> {
    c.connections.iter().find(|s| s.id == id)
}

pub fn active(c: &Config) -> Option<&SavedConnection> {
    c.active_connection.as_deref().and_then(|id| get(c, id))
}

/// Add a validated draft; returns the new id. The first connection becomes the active one.
pub fn add(c: &mut Config, draft: &Draft) -> Result<String, (Field, String)> {
    let d = validate(c, draft, None)?;
    let mut s = SavedConnection { id: next_id(c), ..Default::default() };
    apply_draft(&mut s, &d);
    let id = s.id.clone();
    c.connections.push(s);
    if c.active_connection.is_none() {
        let _ = activate(c, &id);
    }
    Ok(id)
}

/// Replace a connection's settings. Editing the active one updates `host` / `accept_incoming`
/// too. Returns whether the active connection's *target* changed (the viewer must restart).
pub fn update(c: &mut Config, id: &str, draft: &Draft) -> Result<bool, (Field, String)> {
    let d = validate(c, draft, Some(id))?;
    let Some(s) = c.connections.iter_mut().find(|s| s.id == id) else {
        return Err((Field::Name, "That connection no longer exists".into()));
    };
    let before = (s.address.clone(), s.accept_incoming);
    apply_draft(s, &d);
    let changed = before != (s.address.clone(), s.accept_incoming);
    if c.active_connection.as_deref() == Some(id) {
        let _ = activate(c, id);
        return Ok(changed);
    }
    Ok(false)
}

/// A copy named "<name> (copy)" (then "(copy 2)", …). Returns the new id.
pub fn duplicate(c: &mut Config, id: &str) -> Option<String> {
    let src = get(c, id)?.clone();
    let taken = |n: &str| c.connections.iter().any(|s| s.name.to_lowercase() == n.to_lowercase());
    let mut name = format!("{} (copy)", src.name);
    let mut k = 2;
    while taken(&name) {
        name = format!("{} (copy {k})", src.name);
        k += 1;
    }
    let s = SavedConnection { id: next_id(c), name, last_connected: None, ..src };
    let new = s.id.clone();
    c.connections.push(s);
    Some(new)
}

/// What `remove` did, for the caller to report / act on.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Removed {
    pub name: String,
    /// It was the active connection. Another one (if any) is now active, and the viewer should
    /// restart onto it.
    pub was_active: bool,
    /// The host key pinned for it was forgotten (no other connection uses that address).
    pub unpaired: bool,
}

/// Delete a connection. Its pairing (and remembered display) are forgotten unless another saved
/// connection still uses the same address. Removing the active one activates the next
/// supported connection, or clears `host` if none is left.
pub fn remove(c: &mut Config, id: &str) -> Option<Removed> {
    let pos = c.connections.iter().position(|s| s.id == id)?;
    let s = c.connections.remove(pos);
    let key = s.pin_key(c.listen_port);
    let shared = c.connections.iter().any(|o| o.pin_key(c.listen_port) == key);
    let mut out = Removed { name: s.name.clone(), ..Default::default() };
    if !shared {
        out.unpaired = c.pinned_hosts.remove(&key).is_some();
        c.last_display.remove(&key);
    }
    // A viewer paired while listening keeps that pin under "listen:PORT" and `pairing` falls
    // back to it, so it must go too unless another connection still depends on it: a
    // listen-only one (its own key), or one with an address that has no pin of its own yet.
    if let Some(f) = pin_fallback(&s.target(c.listen_port)) {
        let needed = c.connections.iter().any(|o| {
            let t = o.target(c.listen_port);
            pin_target(&t) == f || (pin_fallback(&t).as_deref() == Some(f.as_str()) && !c.pinned_hosts.contains_key(&pin_target(&t)))
        });
        if !needed && c.pinned_hosts.remove(&f).is_some() {
            out.unpaired = true;
        }
    }
    if c.active_connection.as_deref() == Some(id) {
        out.was_active = true;
        c.active_connection = None;
        match c.connections.iter().find(|o| o.is_supported()).map(|o| o.id.clone()) {
            Some(next) => {
                let _ = activate(c, &next);
            }
            None => c.host = None,
        }
    }
    Some(out)
}

/// Forget the pairing of a saved connection (it pairs again on the next connect).
pub fn unpair(c: &mut Config, id: &str) -> bool {
    let Some(s) = get(c, id) else { return false };
    let t = s.target(c.listen_port);
    let mut any = c.pinned_hosts.remove(&pin_target(&t)).is_some();
    if let Some(f) = pin_fallback(&t) {
        any |= c.pinned_hosts.remove(&f).is_some();
    }
    any
}

/// Make `id` the active connection and mirror it into `host` / `accept_incoming`. Returns
/// whether the effective target changed (the running viewer needs a restart to use it).
pub fn activate(c: &mut Config, id: &str) -> Result<bool, String> {
    let s = get(c, id).ok_or_else(|| "That connection no longer exists".to_string())?;
    if !s.is_supported() {
        return Err(format!("“{}” is a {} connection, which this viewer can't open", s.name, s.platform));
    }
    let before = (c.host.clone(), c.accept_incoming);
    let host = Some(s.address.trim().to_string()).filter(|a| !a.is_empty());
    let accept = s.accept_incoming;
    // Inbound admission: trust on first use pins the first Mac that connects in
    // (`allowed_peers` = that one address), and only a Mac whose key is pinned may roam past it.
    // A Mac this viewer hasn't paired with yet could then never connect in to pair, so
    // switching to one resets that automatic pin to "first use" again (as Forget host does in
    // listen mode). Hand-written lists (CIDRs, several entries) are left alone.
    if s.pairing(c).is_none() && crate::peers::is_roamable(&c.allowed_peers) && s.target(c.listen_port) != current_target(c) {
        c.allowed_peers.clear();
    }
    c.host = host;
    // Listen-only keeps the user's accept setting; it means nothing without an address.
    if c.host.is_some() {
        c.accept_incoming = accept;
    }
    c.active_connection = Some(id.to_string());
    Ok(before != (c.host.clone(), c.accept_incoming))
}

/// The target `host` / `accept_incoming` / `listen_port` describe (what a plain launch uses).
fn current_target(c: &Config) -> TargetSpec {
    crate::config::resolve_target(None, None, false, c)
}

/// Reconcile the list with `host` / `accept_incoming` (written by the Set up dialog, by hand, or
/// by an older viewer): update the active connection, else switch to a saved one with that
/// address, else save it as a new connection. Also drops a dangling `active_connection`.
/// Returns whether anything changed.
pub fn sync_from_host(c: &mut Config) -> bool {
    let before = (c.connections.clone(), c.active_connection.clone());
    if active(c).is_none() {
        c.active_connection = None;
    }
    let host = c.host.as_deref().map(str::trim).filter(|h| !h.is_empty()).map(str::to_string);
    let same = |a: &str, b: &str| crate::net::parse_addr(a.trim()).eq_ignore_ascii_case(&crate::net::parse_addr(b.trim()));
    match host {
        Some(h) => {
            let accept = c.accept_incoming;
            if active(c).is_some_and(|s| same(&s.address, &h) && s.accept_incoming == accept) {
                // Already in sync.
            } else if let Some(s) = c.connections.iter_mut().find(|s| s.is_supported() && !s.address.trim().is_empty() && same(&s.address, &h)) {
                s.accept_incoming = accept;
                c.active_connection = Some(s.id.clone());
            } else if let Some(id) = c.active_connection.clone().filter(|_| active(c).is_some_and(|s| same(&s.address, &h))) {
                if let Some(s) = c.connections.iter_mut().find(|s| s.id == id) {
                    s.accept_incoming = accept;
                }
            } else {
                // New address: a new saved connection, named after the paired Mac if known.
                let key = pin_target(&TargetSpec::Connect(h.clone()));
                let name = c.pinned_hosts.get(&key).map(|p| p.name.trim().to_string()).filter(|n| !n.is_empty()).unwrap_or_else(|| h.clone());
                let name = unique_name(c, &name);
                let s = SavedConnection { id: next_id(c), name, address: h, accept_incoming: accept, ..Default::default() };
                c.active_connection = Some(s.id.clone());
                c.connections.push(s);
            }
        }
        None => {
            // No address: the active connection must be a listen-only one (or none).
            if active(c).is_some_and(|s| !s.address.trim().is_empty()) {
                c.active_connection = c.connections.iter().find(|s| s.is_supported() && s.address.trim().is_empty()).map(|s| s.id.clone());
            }
        }
    }
    before != (c.connections.clone(), c.active_connection.clone())
}

fn unique_name(c: &Config, base: &str) -> String {
    let taken = |n: &str| c.connections.iter().any(|s| s.name.to_lowercase() == n.to_lowercase());
    if !taken(base) {
        return base.to_string();
    }
    (2..).map(|k| format!("{base} ({k})")).find(|n| !taken(n)).unwrap_or_default()
}

/// Record that a session with the active connection just started.
pub fn touch_active(c: &mut Config, now: std::time::SystemTime) {
    let Some(id) = c.active_connection.clone() else { return };
    if let Some(s) = c.connections.iter_mut().find(|s| s.id == id) {
        s.last_connected = Some(crate::config::rfc3339_utc(now));
    }
}

/// Find a connection by id, name or address (case-insensitive; `--connection`).
pub fn find<'a>(c: &'a Config, query: &str) -> Option<&'a SavedConnection> {
    let q = query.trim();
    if q.is_empty() {
        return None;
    }
    let lq = q.to_lowercase();
    get(c, q)
        .or_else(|| c.connections.iter().find(|s| s.name.to_lowercase() == lq))
        .or_else(|| c.connections.iter().find(|s| !s.address.trim().is_empty() && s.address.trim().eq_ignore_ascii_case(q)))
}

/// Distinct group names, sorted case-insensitively (for the group picker).
pub fn groups(c: &Config) -> Vec<String> {
    let mut g: Vec<String> = c.connections.iter().filter_map(|s| s.group.clone()).collect();
    g.sort_by_key(|a| a.to_lowercase());
    g.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
    g
}

/// One line of the Connections list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub name: String,
    pub address: String,
    pub group: String,
    /// "Paired with MacBook Pro" / "Not paired" / "Not supported here".
    pub status: String,
    pub paired: bool,
    /// "Just now", "3 hours ago", "Never".
    pub last_used: String,
    pub active: bool,
    pub favorite: bool,
    pub supported: bool,
}

/// The rows to show: those matching `filter` (name, address or group; case-insensitive),
/// grouped (ungrouped first, then groups A→Z), favorites first within a group, then by name.
pub fn rows(c: &Config, filter: &str, now: std::time::SystemTime) -> Vec<Row> {
    let f = filter.trim().to_lowercase();
    let mut v: Vec<&SavedConnection> = c
        .connections
        .iter()
        .filter(|s| {
            f.is_empty()
                || s.name.to_lowercase().contains(&f)
                || s.address.to_lowercase().contains(&f)
                || s.group.as_deref().is_some_and(|g| g.to_lowercase().contains(&f))
        })
        .collect();
    v.sort_by_key(|s| (s.group.as_ref().map(|g| g.to_lowercase()), !s.favorite, s.name.to_lowercase()));
    v.into_iter()
        .map(|s| {
            let pin = if s.is_supported() { s.pairing(c) } else { None };
            let status = if !s.is_supported() {
                "Not supported by this viewer".to_string()
            } else {
                match pin {
                    Some(p) if !p.name.trim().is_empty() => format!("Paired with {}", p.name.trim()),
                    Some(_) => "Paired".into(),
                    None => "Not paired yet".into(),
                }
            };
            Row {
                id: s.id.clone(),
                name: s.name.clone(),
                address: s.address_label(),
                group: s.group.clone().unwrap_or_default(),
                status,
                paired: pin.is_some(),
                last_used: s.last_connected.as_deref().map(|t| relative_time(t, now)).unwrap_or_else(|| "Never".into()),
                active: c.active_connection.as_deref() == Some(s.id.as_str()),
                favorite: s.favorite,
                supported: s.is_supported(),
            }
        })
        .collect()
}

/// Supported connections for the tray's quick-connect submenu: favorites first, then most
/// recently used, then by name; at most `max`.
pub fn quick_list(c: &Config, max: usize) -> Vec<(String, String, bool)> {
    let mut v: Vec<&SavedConnection> = c.connections.iter().filter(|s| s.is_supported()).collect();
    v.sort_by(|a, b| {
        (!a.favorite, std::cmp::Reverse(a.last_connected.as_deref().and_then(parse_rfc3339)), a.name.to_lowercase()).cmp(&(
            !b.favorite,
            std::cmp::Reverse(b.last_connected.as_deref().and_then(parse_rfc3339)),
            b.name.to_lowercase(),
        ))
    });
    v.into_iter().take(max).map(|s| (s.id.clone(), s.name.clone(), c.active_connection.as_deref() == Some(s.id.as_str()))).collect()
}

/// Seconds since the Unix epoch for "YYYY-MM-DDTHH:MM:SSZ" (the form `rfc3339_utc` writes).
pub fn parse_rfc3339(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'Z' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, m, d, hh, mm, ss) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + hh * 3600 + mm * 60 + ss)
}

/// "Just now", "5 minutes ago", "Yesterday", "12 days ago", or the date for older ones.
pub fn relative_time(rfc3339: &str, now: std::time::SystemTime) -> String {
    let Some(t) = parse_rfc3339(rfc3339) else { return "Unknown".into() };
    let now = now.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let d = (now - t).max(0);
    let plural = |n: i64, unit: &str| if n == 1 { format!("1 {unit} ago") } else { format!("{n} {unit}s ago") };
    match d {
        0..=59 => "Just now".into(),
        60..=3599 => plural(d / 60, "minute"),
        3600..=86399 => plural(d / 3600, "hour"),
        86400..=172799 => "Yesterday".into(),
        _ if d < 30 * 86400 => plural(d / 86400, "day"),
        _ => rfc3339.get(0..10).unwrap_or(rfc3339).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PinnedHost;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    const KEY: &str = "0000000000000000000000000000000000000000000000000000000000000001";

    fn draft(name: &str, addr: &str) -> Draft {
        Draft { name: name.into(), address: addr.into(), accept_incoming: true, ..Default::default() }
    }

    fn pin(c: &mut Config, target: &str, name: &str) {
        c.pinned_hosts.insert(target.into(), PinnedHost { key: KEY.into(), name: name.into(), paired: "2026-01-01T00:00:00Z".into() });
    }

    #[test]
    fn first_added_becomes_active_and_mirrors_host() {
        let mut c = Config::default();
        let id = add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        assert_eq!(id, "c1");
        assert_eq!(c.active_connection.as_deref(), Some("c1"));
        assert_eq!(c.host.as_deref(), Some("192.168.1.20"));
        let id2 = add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        assert_eq!(id2, "c2");
        assert_eq!(c.active_connection.as_deref(), Some("c1"), "adding more doesn't switch");
    }

    #[test]
    fn validate_fills_name_rejects_dupes_and_bad_addresses() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        let d = validate(&c, &draft("  ", " 10.0.0.9 "), None).unwrap();
        assert_eq!(d.name, "10.0.0.9");
        assert_eq!(d.address, "10.0.0.9");
        assert_eq!(validate(&c, &draft("studio", "10.0.0.9"), None).unwrap_err().0, Field::Name);
        assert!(validate(&c, &draft("studio", "10.0.0.9"), Some("c1")).is_ok(), "own name is fine when editing");
        assert_eq!(validate(&c, &draft("X", "10.0.0.9:0"), None).unwrap_err().0, Field::Address);
        assert_eq!(validate(&c, &draft("X", "http://mac"), None).unwrap_err().0, Field::Address);
        assert_eq!(validate(&c, &draft(&"n".repeat(65), ""), None).unwrap_err().0, Field::Name);
        let listen = validate(&c, &draft("", ""), None).unwrap();
        assert!(listen.address.is_empty());
        assert!(!listen.name.is_empty());
        assert_eq!(validate(&c, &Draft { group: "  Home   office ".into(), ..draft("Y", "") }, None).unwrap().group, "Home office");
    }

    #[test]
    fn editing_active_reports_target_change() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        assert!(!update(&mut c, "c1", &Draft { group: "Home".into(), ..draft("Studio Mac", "192.168.1.20") }).unwrap());
        assert_eq!(get(&c, "c1").unwrap().group.as_deref(), Some("Home"));
        assert!(update(&mut c, "c1", &draft("Studio Mac", "192.168.1.21")).unwrap());
        assert_eq!(c.host.as_deref(), Some("192.168.1.21"));
        assert!(!update(&mut c, "c2", &draft("Laptop", "10.0.0.6")).unwrap(), "inactive edits never restart");
        assert_eq!(c.host.as_deref(), Some("192.168.1.21"));
    }

    #[test]
    fn activate_switches_host_and_accept() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &Draft { accept_incoming: false, ..draft("Laptop", "10.0.0.5") }).unwrap();
        assert!(activate(&mut c, "c2").unwrap());
        assert_eq!((c.host.as_deref(), c.accept_incoming), (Some("10.0.0.5"), false));
        assert!(!activate(&mut c, "c2").unwrap());
        assert!(activate(&mut c, "nope").is_err());
        c.connections.push(SavedConnection { id: "c9".into(), name: "PC".into(), platform: "windows".into(), address: "1.2.3.4".into(), ..Default::default() });
        assert!(activate(&mut c, "c9").is_err());
        assert_eq!(c.active_connection.as_deref(), Some("c2"));
    }

    #[test]
    fn listen_only_connection_clears_host() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Wait", "")).unwrap();
        assert!(activate(&mut c, "c2").unwrap());
        assert_eq!(c.host, None);
        assert_eq!(get(&c, "c2").unwrap().target(7420), TargetSpec::Listen(7420));
    }

    #[test]
    fn remove_active_falls_back_and_forgets_unshared_pin() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        pin(&mut c, "192.168.1.20:7420", "Studio");
        let r = remove(&mut c, "c1").unwrap();
        assert!(r.was_active && r.unpaired);
        assert!(c.pinned_hosts.is_empty());
        assert_eq!(c.active_connection.as_deref(), Some("c2"));
        assert_eq!(c.host.as_deref(), Some("10.0.0.5"));
        let r = remove(&mut c, "c2").unwrap();
        assert!(r.was_active && !r.unpaired);
        assert_eq!((c.active_connection.as_deref(), c.host.as_deref()), (None, None));
        assert!(remove(&mut c, "c2").is_none());
    }

    #[test]
    fn remove_keeps_pin_shared_with_another_connection() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        duplicate(&mut c, "c1").unwrap();
        pin(&mut c, "192.168.1.20:7420", "Studio");
        let r = remove(&mut c, "c2").unwrap();
        assert!(!r.unpaired && !r.was_active);
        assert_eq!(c.pinned_hosts.len(), 1);
    }

    #[test]
    fn remove_forgets_listen_fallback_pin_unless_still_needed() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        // Paired while listening, then the address was entered (app copies the pin across).
        pin(&mut c, "listen:7420", "Studio");
        pin(&mut c, "192.168.1.20:7420", "Studio");
        pin(&mut c, "10.0.0.5:7420", "Laptop");
        // The laptop has its own pin, so nothing else needs the fallback.
        assert!(remove(&mut c, "c1").unwrap().unpaired);
        assert!(!c.pinned_hosts.contains_key("listen:7420"));
        assert!(get(&c, "c2").unwrap().pairing(&c).is_some());

        // An address-bearing connection without its own pin still relies on the fallback.
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Other", "10.0.0.5")).unwrap();
        pin(&mut c, "listen:7420", "Studio");
        remove(&mut c, "c1").unwrap();
        assert!(c.pinned_hosts.contains_key("listen:7420"));

        // So does a listen-only connection.
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Wait", "")).unwrap();
        pin(&mut c, "listen:7420", "Studio");
        remove(&mut c, "c1").unwrap();
        assert!(c.pinned_hosts.contains_key("listen:7420"));
    }

    #[test]
    fn switching_to_unpaired_mac_resets_tofu_admission_only() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        add(&mut c, &draft("Paired", "10.0.0.6")).unwrap();
        pin(&mut c, "10.0.0.6:7420", "Paired");
        // TOFU pinned Studio's address after an inbound session.
        c.allowed_peers = vec!["192.168.1.20".into()];
        // To a paired Mac: it may roam past the pin, nothing to reset.
        activate(&mut c, "c3").unwrap();
        assert_eq!(c.allowed_peers, ["192.168.1.20"]);
        // To an unpaired one: back to first use, so it can connect in and pair.
        activate(&mut c, "c2").unwrap();
        assert!(c.allowed_peers.is_empty());
        // A hand-written allowlist stays.
        c.allowed_peers = vec!["192.168.1.0/24".into()];
        activate(&mut c, "c1").unwrap();
        assert_eq!(c.allowed_peers, ["192.168.1.0/24"]);
        // Re-activating the current target changes nothing.
        c.allowed_peers = vec!["192.168.1.20".into()];
        activate(&mut c, "c1").unwrap();
        assert_eq!(c.allowed_peers, ["192.168.1.20"]);
    }

    #[test]
    fn duplicate_names_copies() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        let a = duplicate(&mut c, "c1").unwrap();
        let b = duplicate(&mut c, "c1").unwrap();
        assert_eq!(get(&c, &a).unwrap().name, "Studio (copy)");
        assert_eq!(get(&c, &b).unwrap().name, "Studio (copy 2)");
        assert_eq!(c.active_connection.as_deref(), Some("c1"));
    }

    #[test]
    fn sync_migrates_an_old_single_host_config() {
        let mut c = Config { host: Some("192.168.1.20".into()), accept_incoming: false, ..Default::default() };
        pin(&mut c, "192.168.1.20:7420", "Studio MacBook");
        assert!(sync_from_host(&mut c));
        assert_eq!(c.connections.len(), 1);
        let s = &c.connections[0];
        assert_eq!((s.name.as_str(), s.address.as_str(), s.accept_incoming), ("Studio MacBook", "192.168.1.20", false));
        assert_eq!(c.active_connection.as_deref(), Some("c1"));
        assert!(!sync_from_host(&mut c), "idempotent");
    }

    #[test]
    fn sync_follows_setup_dialog_changes() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        add(&mut c, &draft("Laptop", "10.0.0.5")).unwrap();
        // Set up dialog typed the laptop's address: switch to it rather than adding a duplicate.
        c.host = Some("10.0.0.5:7420".into());
        assert!(sync_from_host(&mut c));
        assert_eq!(c.active_connection.as_deref(), Some("c2"));
        assert_eq!(c.connections.len(), 2);
        // A new address becomes a new connection.
        c.host = Some("172.16.0.2".into());
        assert!(sync_from_host(&mut c));
        assert_eq!(c.connections.len(), 3);
        assert_eq!(active(&c).unwrap().address, "172.16.0.2");
        // accept_incoming flipped in the dialog updates the active one.
        c.accept_incoming = false;
        assert!(sync_from_host(&mut c));
        assert!(!active(&c).unwrap().accept_incoming);
        // Dangling active id is dropped; a cleared host leaves no address-bearing active.
        c.host = None;
        sync_from_host(&mut c);
        assert_eq!(c.active_connection, None);
    }

    #[test]
    fn sync_unique_names() {
        let mut c = Config::default();
        add(&mut c, &draft("10.0.0.5", "10.0.0.6")).unwrap();
        c.host = Some("10.0.0.5".into());
        sync_from_host(&mut c);
        assert_eq!(active(&c).unwrap().name, "10.0.0.5 (2)");
    }

    #[test]
    fn rows_group_sort_filter_and_status() {
        let mut c = Config::default();
        add(&mut c, &Draft { group: "Office".into(), ..draft("Zeta", "10.0.0.1") }).unwrap();
        add(&mut c, &draft("beta", "10.0.0.2")).unwrap();
        add(&mut c, &Draft { group: "Office".into(), favorite: true, ..draft("Omega", "10.0.0.3") }).unwrap();
        add(&mut c, &draft("Alpha", "")).unwrap();
        pin(&mut c, "10.0.0.2:7420", "Beta Mac");
        let now = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let r = rows(&c, "", now);
        let names: Vec<_> = r.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["Alpha", "beta", "Omega", "Zeta"]);
        assert_eq!(r[1].status, "Paired with Beta Mac");
        assert!(r[1].paired);
        assert_eq!(r[0].address, "Waits for the Mac to connect");
        assert!(r[3].active);
        assert_eq!(r[0].last_used, "Never");
        let f: Vec<_> = rows(&c, "office", now).into_iter().map(|r| r.name).collect();
        assert_eq!(f, ["Omega", "Zeta"]);
        assert_eq!(rows(&c, "10.0.0.2", now).len(), 1);
    }

    #[test]
    fn listen_fallback_pin_counts_as_paired() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        pin(&mut c, "listen:7420", "Studio");
        assert!(get(&c, "c1").unwrap().pairing(&c).is_some());
        assert!(unpair(&mut c, "c1"));
        assert!(c.pinned_hosts.is_empty());
    }

    #[test]
    fn quick_list_orders_favorites_then_recent() {
        let mut c = Config::default();
        add(&mut c, &draft("A", "10.0.0.1")).unwrap();
        add(&mut c, &draft("B", "10.0.0.2")).unwrap();
        add(&mut c, &Draft { favorite: true, ..draft("C", "10.0.0.3") }).unwrap();
        c.connections[1].last_connected = Some("2026-05-01T00:00:00Z".into());
        c.connections.push(SavedConnection { id: "c9".into(), name: "PC".into(), platform: "windows".into(), ..Default::default() });
        let q: Vec<_> = quick_list(&c, 10).into_iter().map(|(_, n, _)| n).collect();
        assert_eq!(q, ["C", "B", "A"]);
        assert_eq!(quick_list(&c, 1).len(), 1);
    }

    #[test]
    fn find_by_id_name_address() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio Mac", "192.168.1.20")).unwrap();
        assert_eq!(find(&c, "c1").unwrap().name, "Studio Mac");
        assert_eq!(find(&c, "studio mac").unwrap().id, "c1");
        assert_eq!(find(&c, "192.168.1.20").unwrap().id, "c1");
        assert!(find(&c, "nope").is_none());
        assert!(find(&c, " ").is_none());
    }

    #[test]
    fn touch_and_relative_time() {
        let mut c = Config::default();
        add(&mut c, &draft("Studio", "192.168.1.20")).unwrap();
        let t = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        touch_active(&mut c, t);
        let s = active(&c).unwrap().last_connected.clone().unwrap();
        assert_eq!(parse_rfc3339(&s), Some(1_800_000_000));
        assert_eq!(relative_time(&s, t + Duration::from_secs(5)), "Just now");
        assert_eq!(relative_time(&s, t + Duration::from_secs(120)), "2 minutes ago");
        assert_eq!(relative_time(&s, t + Duration::from_secs(3600)), "1 hour ago");
        assert_eq!(relative_time(&s, t + Duration::from_secs(90_000)), "Yesterday");
        assert_eq!(relative_time(&s, t + Duration::from_secs(5 * 86400)), "5 days ago");
        assert_eq!(relative_time(&s, t + Duration::from_secs(90 * 86400)), &s[0..10]);
        assert_eq!(relative_time("garbage", t), "Unknown");
        assert_eq!(parse_rfc3339(&crate::config::rfc3339_utc(SystemTime::UNIX_EPOCH)), Some(0));
    }

    #[test]
    fn unknown_platform_round_trips() {
        let mut c = Config::default();
        c.connections.push(SavedConnection { id: "c1".into(), name: "Gaming PC".into(), platform: "windows".into(), address: "10.0.0.9".into(), ..Default::default() });
        let back = crate::config::parse(&crate::config::to_json(&c)).config;
        assert_eq!(back.connections[0].platform, "windows");
        assert!(!rows(&back, "", SystemTime::now())[0].supported);
    }
}
