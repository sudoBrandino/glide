//! Session grants on the host (docs/ENTERPRISE.md §6.3): the cloud names the viewer key allowed
//! for one session. A grant lives in memory only (never in host.json's paired viewers), is bound
//! to its session id, expires, and admits exactly one Noise session: `take` removes it.

use super::api::{Permissions, SessionOffer, User};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

/// Longest a grant waits for its handshake: the relay ticket's lifetime (§6.1).
pub const MAX_TTL: Duration = Duration::from_secs(120);
/// Shortest, whatever `expires_at` says (clock skew between this PC and the cloud).
pub const MIN_TTL: Duration = Duration::from_secs(30);
/// Most grants held at once (offers are one per session; this only bounds a misbehaving cloud).
const MAX_GRANTS: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub session_id: String,
    pub viewer_key: [u8; 32],
    pub viewer_name: String,
    pub user: User,
    pub permissions: Permissions,
    pub expires: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrantError {
    /// No grant for that session (never offered, cancelled, or already used).
    Unknown,
    Expired,
    /// The viewer presented another key than the one the cloud named.
    WrongKey,
}

impl std::fmt::Display for GrantError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            GrantError::Unknown => "no grant for this session (unknown, cancelled or already used)",
            GrantError::Expired => "the session grant expired",
            GrantError::WrongKey => "the viewer's key isn't the one the cloud granted",
        })
    }
}

/// How long a grant from an offer lives: until `expires_at` (wall clock), within
/// [`MIN_TTL`, `MAX_TTL`]; `MAX_TTL` when it doesn't parse.
pub fn ttl(expires_at: &str, now: SystemTime) -> Duration {
    let Some(exp) = crate::connections::parse_rfc3339(expires_at) else { return MAX_TTL };
    let now_s = now.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    Duration::from_secs((exp - now_s).max(0) as u64).clamp(MIN_TTL, MAX_TTL)
}

/// Parses the offer's viewer key (64 hex chars).
pub fn parse_key(hex: &str) -> Option<[u8; 32]> {
    let h = hex.trim();
    if h.len() != 64 || !h.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    crate::util::unhex(h).try_into().ok()
}

impl Grant {
    pub fn from_offer(o: &SessionOffer, now: Instant, wall: SystemTime) -> Option<Grant> {
        Some(Grant {
            session_id: o.session_id.clone(),
            viewer_key: parse_key(&o.viewer.public_key)?,
            viewer_name: o.viewer.name.clone(),
            user: o.user.clone(),
            permissions: o.permissions,
            expires: now + ttl(&o.expires_at, wall),
        })
    }
}

#[derive(Default)]
pub struct GrantStore {
    grants: Mutex<HashMap<String, Grant>>,
}

impl GrantStore {
    pub fn insert(&self, g: Grant, now: Instant) {
        let mut m = self.grants.lock().unwrap();
        m.retain(|_, g| g.expires > now);
        if m.len() >= MAX_GRANTS {
            if let Some(oldest) = m.values().min_by_key(|g| g.expires).map(|g| g.session_id.clone()) {
                m.remove(&oldest);
            }
        }
        m.insert(g.session_id.clone(), g);
    }

    /// Consumes the grant for `session_id` if `key` is the granted key and it is still live.
    /// Any attempt on the session uses it up (a wrong key doesn't get a second try).
    pub fn take(&self, session_id: &str, key: &[u8; 32], now: Instant) -> Result<Grant, GrantError> {
        let g = self.grants.lock().unwrap().remove(session_id).ok_or(GrantError::Unknown)?;
        if g.expires <= now {
            return Err(GrantError::Expired);
        }
        if &g.viewer_key != key {
            return Err(GrantError::WrongKey);
        }
        Ok(g)
    }

    /// `session_cancel`, or the host declined after all.
    pub fn cancel(&self, session_id: &str) -> bool {
        self.grants.lock().unwrap().remove(session_id).is_some()
    }

    /// Revoked: forget everything.
    pub fn clear(&self) {
        self.grants.lock().unwrap().clear();
    }

    pub fn len(&self) -> usize {
        self.grants.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::api::OfferViewer;

    fn offer(sid: &str, key: &str, exp: &str) -> SessionOffer {
        SessionOffer {
            session_id: sid.into(),
            viewer: OfferViewer { device_id: "dev_v".into(), name: "PC".into(), public_key: key.into() },
            user: User { id: "usr_1".into(), email: "ada@example.com".into(), name: "Ada".into(), groups: None },
            permissions: Permissions::default(),
            approval: "none".into(),
            relay_url: "wss://c/v1/relay/x".into(),
            ticket: "t".into(),
            expires_at: exp.into(),
        }
    }

    #[test]
    fn single_use_and_bound_to_key_and_session() {
        let now = Instant::now();
        let wall = SystemTime::now();
        let s = GrantStore::default();
        let key = [0xab; 32];
        s.insert(Grant::from_offer(&offer("ses_1", &"ab".repeat(32), ""), now, wall).unwrap(), now);
        assert_eq!(s.take("ses_2", &key, now), Err(GrantError::Unknown), "bound to its session");
        let g = s.take("ses_1", &key, now).unwrap();
        assert_eq!((g.viewer_name.as_str(), g.user.email.as_str()), ("PC", "ada@example.com"));
        assert_eq!(s.take("ses_1", &key, now), Err(GrantError::Unknown), "single use");
        // A wrong key uses the grant up.
        s.insert(Grant::from_offer(&offer("ses_3", &"ab".repeat(32), ""), now, wall).unwrap(), now);
        assert_eq!(s.take("ses_3", &[1; 32], now), Err(GrantError::WrongKey));
        assert_eq!(s.take("ses_3", &key, now), Err(GrantError::Unknown));
        assert!(s.is_empty());
    }

    #[test]
    fn expiry_and_cancel() {
        let now = Instant::now();
        let wall = SystemTime::UNIX_EPOCH + Duration::from_secs(1_764_064_800); // 2025-11-25T10:00:00Z
        let s = GrantStore::default();
        let key = [0xcd; 32];
        let g = Grant::from_offer(&offer("ses_1", &"cd".repeat(32), "2025-11-25T10:01:00Z"), now, wall).unwrap();
        assert_eq!(g.expires - now, Duration::from_secs(60));
        s.insert(g, now);
        assert_eq!(s.take("ses_1", &key, now + Duration::from_secs(61)), Err(GrantError::Expired));
        s.insert(Grant::from_offer(&offer("ses_2", &"cd".repeat(32), ""), now, wall).unwrap(), now);
        assert!(s.cancel("ses_2"));
        assert!(!s.cancel("ses_2"));
        assert_eq!(s.take("ses_2", &key, now), Err(GrantError::Unknown));
        // TTL bounds.
        assert_eq!(ttl("2025-11-25T11:00:00Z", wall), MAX_TTL);
        assert_eq!(ttl("2025-11-25T09:00:00Z", wall), MIN_TTL, "clock skew can't make it unusable");
        assert_eq!(ttl("garbage", wall), MAX_TTL);
        // Expired grants are purged on insert; the store is bounded.
        for i in 0..40 {
            s.insert(Grant::from_offer(&offer(&format!("ses_x{i}"), &"cd".repeat(32), ""), now, wall).unwrap(), now);
        }
        assert!(s.len() <= MAX_GRANTS);
        s.clear();
        assert!(s.is_empty());
    }

    #[test]
    fn bad_keys_make_no_grant() {
        let (now, wall) = (Instant::now(), SystemTime::now());
        assert!(Grant::from_offer(&offer("s", "xyz", ""), now, wall).is_none());
        assert!(Grant::from_offer(&offer("s", &"0".repeat(63), ""), now, wall).is_none());
        assert_eq!(parse_key(&"0F".repeat(32)), Some([0x0f; 32]));
    }
}
