//! Glide Cloud wire formats (docs/ENTERPRISE.md §6–§9): request and response bodies of the device
//! API, hub frames, relay control frames, org settings, session permissions and the error
//! envelope. JSON, with unknown fields ignored (§6). Where a field is missing the most restrictive
//! value is assumed for permissions; settings fall back to the documented defaults (§7).
//!
//! Display strings from the cloud (names, emails, device and org names, error messages) are
//! cleaned of control and bidirectional-override characters as they are decoded (§6.7), so no UI
//! or tray text can be spoofed with them.

use serde::{Deserialize, Deserializer, Serialize};

// ------------------------------------------------------------------ display strings (§6.7)

/// Unicode `General_Category=Cf` (format characters, Unicode 15.1), as ranges. Among them: the
/// soft hyphen, zero-width space / non-joiner / joiner (U+200B–200D), the bidirectional marks,
/// embeddings, overrides and isolates (U+200E/200F, U+202A–202E, U+2066–2069, U+061C), the
/// invisible operators (U+2060–2064), the deprecated format controls (U+206A–206F), the BOM
/// (U+FEFF), interlinear annotation controls and the tag characters.
const FORMAT_CHARS: &[(u32, u32)] = &[
    (0x00AD, 0x00AD),
    (0x0600, 0x0605),
    (0x061C, 0x061C),
    (0x06DD, 0x06DD),
    (0x070F, 0x070F),
    (0x0890, 0x0891),
    (0x08E2, 0x08E2),
    (0x180E, 0x180E),
    (0x200B, 0x200F),
    (0x202A, 0x202E),
    (0x2060, 0x2064),
    (0x2066, 0x206F),
    (0xFEFF, 0xFEFF),
    (0xFFF9, 0xFFFB),
    (0x110BD, 0x110BD),
    (0x110CD, 0x110CD),
    (0x13430, 0x1343F),
    (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A),
    (0xE0001, 0xE0001),
    (0xE0020, 0xE007F),
];

/// Other invisible characters that can disguise text: the line and paragraph separators
/// (`Zl`/`Zp`, U+2028/2029), the whole tag block (U+E0000–E007F), and variation selectors
/// (U+FE00–FE0F, U+E0100–E01EF, and the Mongolian free variation selectors U+180B–180F).
const INVISIBLE_CHARS: &[(u32, u32)] = &[(0x180B, 0x180F), (0x2028, 0x2029), (0xFE00, 0xFE0F), (0xE0000, 0xE007F), (0xE0100, 0xE01EF)];

fn in_ranges(c: char, ranges: &[(u32, u32)]) -> bool {
    let c = c as u32;
    ranges.iter().any(|&(lo, hi)| (lo..=hi).contains(&c))
}

/// A character that must never reach a label (§6.7): C0 and C1 controls and DEL (`Cc`), every
/// format character (`Cf`: bidirectional controls and marks, zero-width characters, BOM, soft
/// hyphen, tags…), line and paragraph separators, and variation selectors.
pub fn unsafe_display_char(c: char) -> bool {
    c.is_control() || in_ranges(c, FORMAT_CHARS) || in_ranges(c, INVISIBLE_CHARS)
}

/// `s` without the characters of `unsafe_display_char`, with each run of whitespace collapsed to
/// one space, trimmed. Every display string from the cloud goes through this.
pub fn clean_display(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for c in s.chars().filter(|&c| !unsafe_display_char(c)) {
        if c.is_whitespace() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
                space = false;
            }
            out.push(c);
        }
    }
    out
}

/// `s` cut to at most `max` characters, the last one an ellipsis when it was longer (on a char
/// boundary, like `host::trust::display_name`).
pub fn truncate_display(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        s.chars().take(max.saturating_sub(1)).collect::<String>() + "…"
    } else {
        s.to_string()
    }
}

/// Longest user name or email shown in a label.
pub const LABEL_PART_MAX: usize = 64;

/// An email cut to at most `max` characters without ever hiding its real domain: the whole
/// domain is kept and only the local part is shortened (`loc…@example.com`). A domain that alone
/// is too long keeps its end, the registrable part (`…@…company.example`). Without an `@` the
/// end is kept the same way (`…tail`).
pub fn truncate_email(e: &str, max: usize) -> String {
    let n = e.chars().count();
    if n <= max {
        return e.to_string();
    }
    let tail = |s: &str, keep: usize| -> String {
        let len = s.chars().count();
        s.chars().skip(len.saturating_sub(keep)).collect()
    };
    let Some((local, domain)) = e.rsplit_once('@') else {
        return format!("…{}", tail(e, max.saturating_sub(1)));
    };
    let domain_len = domain.chars().count();
    if domain_len + 2 <= max {
        // local part + "…" + "@" + domain
        let keep = max - 2 - domain_len;
        format!("{}…@{domain}", local.chars().take(keep).collect::<String>())
    } else {
        format!("…@…{}", tail(domain, max.saturating_sub(3)))
    }
}

/// serde: a display string, cleaned; `null` reads as empty.
fn de_display<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.map(|s| clean_display(&s)).unwrap_or_default())
}

/// serde: a list of display strings (tags), cleaned; `null` reads as empty.
fn de_display_list<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    Ok(Option::<Vec<String>>::deserialize(d)?.unwrap_or_default().iter().map(|s| clean_display(s)).filter(|s| !s.is_empty()).collect())
}

// ------------------------------------------------------------------ errors

/// `{ "error": { "code": "host_offline", "message": "The host is not connected." } }`
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct ErrorBody {
    pub code: String,
    #[serde(deserialize_with = "de_display")]
    pub message: String,
}

// ------------------------------------------------------------------ settings (§7)

/// Effective org settings for a device.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(default)]
pub struct Settings {
    pub lan_mode: bool,
    pub allow_local_pairing: bool,
    pub owner_access: bool,
    pub user_session_hours: u32,
    pub session_max_minutes: u32,
    pub audit_file_names: bool,
    pub audit_retention_days: u32,
    pub min_app_version: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            lan_mode: true,
            allow_local_pairing: true,
            owner_access: true,
            user_session_hours: 12,
            session_max_minutes: 480,
            audit_file_names: true,
            audit_retention_days: 365,
            min_app_version: None,
        }
    }
}

// ------------------------------------------------------------------ permissions (§6.3)

/// Direction of clipboard / file data, from the data's point of view (`to_host` = viewer → host).
/// An unknown value reads as `off`.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Direction {
    #[serde(rename = "both")]
    Both,
    #[serde(rename = "to_host")]
    ToHost,
    #[serde(rename = "to_viewer")]
    ToViewer,
    #[default]
    #[serde(rename = "off", other)]
    Off,
}

impl Direction {
    pub fn to_host(self) -> bool {
        matches!(self, Direction::Both | Direction::ToHost)
    }
    pub fn to_viewer(self) -> bool {
        matches!(self, Direction::Both | Direction::ToViewer)
    }
    pub fn from_flags(to_host: bool, to_viewer: bool) -> Direction {
        match (to_host, to_viewer) {
            (true, true) => Direction::Both,
            (true, false) => Direction::ToHost,
            (false, true) => Direction::ToViewer,
            (false, false) => Direction::Off,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Direction::Both => "both",
            Direction::ToHost => "to_host",
            Direction::ToViewer => "to_viewer",
            Direction::Off => "off",
        }
    }
}

/// What a session allows. Missing fields are the most restrictive value.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct Permissions {
    pub control: bool,
    pub clipboard: Direction,
    pub files: Direction,
    pub audio: bool,
}

// ------------------------------------------------------------------ shared objects

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct Org {
    pub id: String,
    #[serde(deserialize_with = "de_display")]
    pub slug: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct User {
    pub id: String,
    #[serde(deserialize_with = "de_display")]
    pub email: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<String>>,
}

impl User {
    /// "Ada Lovelace (ada@example.com)", or just the email; "an organization user" without
    /// either. Cleaned with `clean_display` (§6.7); name and email are each cut to
    /// `LABEL_PART_MAX` characters (the name at its end, the email in its local part, so the
    /// domain shown is always the real one: `truncate_email`).
    pub fn label(&self) -> String {
        let (n, e) = (truncate_display(&clean_display(&self.name), LABEL_PART_MAX), truncate_email(&clean_display(&self.email), LABEL_PART_MAX));
        match (n.is_empty(), e.is_empty()) {
            (false, false) if n != e => format!("{n} ({e})"),
            (false, _) => n,
            (true, false) => e,
            (true, true) => "an organization user".into(),
        }
    }
}

// ------------------------------------------------------------------ device API (§6.2)

/// `POST /v1/enroll` (no bearer).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct EnrollRequest {
    pub enrollment_token: String,
    /// "host" | "viewer"
    pub kind: String,
    /// 64 hex chars.
    pub public_key: String,
    pub name: String,
    /// "macos" | "windows"
    pub platform: String,
    pub os_version: String,
    pub app_version: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub tags: Option<Vec<String>>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct EnrollResponse {
    pub device_id: String,
    pub device_token: String,
    #[serde(default)]
    pub org: Org,
    #[serde(default)]
    pub settings: Settings,
}

/// `GET /v1/device`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct DeviceInfo {
    pub device_id: String,
    pub kind: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
    #[serde(deserialize_with = "de_display_list")]
    pub tags: Vec<String>,
    pub org: Org,
    pub settings: Settings,
}

/// `POST /v1/device/heartbeat`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct HeartbeatRequest {
    pub app_version: String,
    pub os_version: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub name: Option<String>,
}

/// One client audit event (§9). `detail` depends on `type`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct AuditEvent {
    #[serde(rename = "type")]
    pub kind: String,
    pub ts: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub detail: serde_json::Value,
}

/// `POST /v1/audit` (≤ 100 events).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct AuditBatch {
    pub events: Vec<AuditEvent>,
}

/// `POST /v1/auth/device/start`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DeviceStartResponse {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: String,
    #[serde(default = "default_interval")]
    pub interval: u64,
    #[serde(default = "default_expires")]
    pub expires_in: u64,
}

fn default_interval() -> u64 {
    5
}
fn default_expires() -> u64 {
    600
}

/// `POST /v1/auth/device/token`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DeviceTokenRequest {
    pub device_code: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DeviceTokenResponse {
    pub user_token: String,
    pub expires_in: u64,
    #[serde(default)]
    pub user: User,
}

/// `GET /v1/me`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct MeResponse {
    pub user: User,
    pub org: Org,
}

/// One entry of `GET /v1/hosts`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct HostEntry {
    pub id: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
    pub platform: String,
    #[serde(deserialize_with = "de_display_list")]
    pub tags: Vec<String>,
    pub online: bool,
    pub last_seen: Option<String>,
    pub permissions: Permissions,
    /// "none" | "required"
    pub approval: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct HostsResponse {
    pub hosts: Vec<HostEntry>,
}

/// `POST /v1/sessions`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SessionRequest {
    pub host_id: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub view_only: Option<bool>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct SessionHost {
    pub id: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
    pub public_key: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SessionResponse {
    pub session_id: String,
    pub relay_url: String,
    pub ticket: String,
    pub host: SessionHost,
    #[serde(default)]
    pub permissions: Permissions,
    #[serde(default)]
    pub approval_required: bool,
    #[serde(default)]
    pub expires_at: String,
}

// ------------------------------------------------------------------ hub (§6.4)

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct OfferViewer {
    pub device_id: String,
    #[serde(deserialize_with = "de_display")]
    pub name: String,
    pub public_key: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SessionOffer {
    pub session_id: String,
    pub viewer: OfferViewer,
    #[serde(default)]
    pub user: User,
    #[serde(default)]
    pub permissions: Permissions,
    /// "none" | "required"; anything else is treated as "required".
    #[serde(default)]
    pub approval: String,
    pub relay_url: String,
    pub ticket: String,
    #[serde(default)]
    pub expires_at: String,
}

impl SessionOffer {
    pub fn approval_required(&self) -> bool {
        self.approval != "none"
    }
}

/// Server → device hub frames. Unknown types parse as `Unknown` (ignored).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerFrame {
    Hello {
        #[serde(default)]
        device_id: String,
        #[serde(default)]
        settings: Settings,
        #[serde(default)]
        server_time: String,
    },
    SessionOffer(Box<SessionOffer>),
    SessionCancel {
        session_id: String,
        #[serde(default)]
        reason: String,
    },
    Settings {
        settings: Settings,
    },
    Revoked {
        #[serde(default, deserialize_with = "de_display")]
        reason: String,
    },
    Ping {
        #[serde(default)]
        t: serde_json::Value,
    },
    #[serde(other)]
    Unknown,
}

/// Device → server hub frames.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DeviceFrame {
    SessionAnswer {
        session_id: String,
        accept: bool,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        reason: Option<String>,
    },
    SessionState {
        session_id: String,
        /// "connected" | "ended"
        state: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        detail: Option<String>,
    },
    Pong {
        t: serde_json::Value,
    },
}

/// Why a host declines an offer (`session_answer.reason`).
pub mod decline {
    pub const DECLINED: &str = "declined";
    pub const BUSY: &str = "busy";
    pub const TIMEOUT: &str = "timeout";
    pub const POLICY: &str = "policy";
}

// ------------------------------------------------------------------ relay (§6.5)

/// Relay → client text frames.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayControl {
    Waiting,
    PeerJoined,
    PeerLeft,
    #[serde(other)]
    Unknown,
}

/// Relay close codes.
pub mod close {
    pub const NORMAL: u16 = 1000;
    pub const TICKET_INVALID: u16 = 4001;
    pub const PROTOCOL: u16 = 4002;
    pub const ENDED_BY_ADMIN: u16 = 4003;
    pub const PEER_DID_NOT_JOIN: u16 = 4004;
    pub const TIME_LIMIT: u16 = 4005;

    /// What the user is told when the relay closes a session with `code`.
    pub fn describe(code: u16) -> &'static str {
        match code {
            NORMAL => "the session ended",
            TICKET_INVALID => "the relay refused the session ticket",
            PROTOCOL => "the relay closed the session (protocol error)",
            ENDED_BY_ADMIN => "an administrator ended the session",
            PEER_DID_NOT_JOIN => "the other computer didn't join the session",
            TIME_LIMIT => "the session reached its time limit",
            _ => "the relay closed the session",
        }
    }
}

// ------------------------------------------------------------------ audit types (§9)

pub mod audit_type {
    pub const FILE_SENT: &str = "session.file_sent";
    pub const FILE_RECEIVED: &str = "session.file_received";
    pub const CLIPBOARD: &str = "session.clipboard";
    pub const LOCAL_END: &str = "session.local_end";
    pub const CLIENT_ERROR: &str = "client.error";
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rt<T: Serialize + for<'de> Deserialize<'de> + PartialEq + std::fmt::Debug>(text: &str) -> T {
        let v: T = serde_json::from_str(text).expect("parses");
        let again: T = serde_json::from_str(&serde_json::to_string(&v).unwrap()).unwrap();
        assert_eq!(v, again, "round trip");
        v
    }

    // Examples verbatim from docs/ENTERPRISE.md.

    #[test]
    fn error_envelope() {
        let e: ErrorEnvelope = rt(r#"{ "error": { "code": "host_offline", "message": "The host is not connected." } }"#);
        assert_eq!(e.error.code, "host_offline");
        assert_eq!(e.error.message, "The host is not connected.");
    }

    #[test]
    fn permissions_example() {
        let p: Permissions = rt(r#"{ "control": true, "clipboard": "both", "files": "both", "audio": true }"#);
        assert_eq!(p, Permissions { control: true, clipboard: Direction::Both, files: Direction::Both, audio: true });
        // From the §8 policy example.
        let p: Permissions = rt(r#"{ "control": true, "clipboard": "both", "files": "to_host", "audio": false }"#);
        assert_eq!((p.files, p.audio), (Direction::ToHost, false));
        // Missing fields and unknown directions are the most restrictive.
        let p: Permissions = serde_json::from_str(r#"{"clipboard":"sideways"}"#).unwrap();
        assert_eq!(p, Permissions::default());
        assert_eq!(p.clipboard, Direction::Off);
        assert!(!p.control && !p.audio);
        assert_eq!(serde_json::to_value(Direction::ToViewer).unwrap(), json!("to_viewer"));
    }

    #[test]
    fn settings_example() {
        let s: Settings = rt(r#"{
  "lan_mode": true,
  "allow_local_pairing": true,
  "owner_access": true,
  "user_session_hours": 12,
  "session_max_minutes": 480,
  "audit_file_names": true,
  "audit_retention_days": 365,
  "min_app_version": null
}"#);
        assert_eq!(s, Settings::default());
        let s: Settings = serde_json::from_str(r#"{"lan_mode":false,"min_app_version":"0.4.0","extra":1}"#).unwrap();
        assert!(!s.lan_mode && s.allow_local_pairing);
        assert_eq!(s.min_app_version.as_deref(), Some("0.4.0"));
    }

    #[test]
    fn enroll_round_trip() {
        let req = EnrollRequest {
            enrollment_token: "enr_tok".into(),
            kind: "host".into(),
            public_key: "ab".repeat(32),
            name: "GAMING-PC".into(),
            platform: "windows".into(),
            os_version: "10.0.26100".into(),
            app_version: "0.3.1".into(),
            tags: None,
        };
        let v = serde_json::to_value(&req).unwrap();
        assert_eq!(
            v,
            json!({"enrollment_token":"enr_tok","kind":"host","public_key":"ab".repeat(32),"name":"GAMING-PC","platform":"windows","os_version":"10.0.26100","app_version":"0.3.1"})
        );
        let r: EnrollResponse = rt(r#"{"device_id":"dev_01","device_token":"gd_x","org":{"id":"org_1","slug":"acme","name":"Acme"},"settings":{"lan_mode":false}}"#);
        assert_eq!((r.org.slug.as_str(), r.settings.lan_mode, r.settings.user_session_hours), ("acme", false, 12));
    }

    #[test]
    fn device_api_bodies() {
        let d: DeviceInfo = rt(r#"{"device_id":"dev_1","kind":"viewer","name":"PC","tags":["a"],"org":{"id":"org_1","slug":"s","name":"N"},"settings":{}}"#);
        assert_eq!(d.tags, vec!["a"]);
        let hb = serde_json::to_value(HeartbeatRequest { app_version: "0.3.1".into(), os_version: "10".into(), name: None }).unwrap();
        assert_eq!(hb, json!({"app_version":"0.3.1","os_version":"10"}));
        let ds: DeviceStartResponse = rt(r#"{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://c/auth/device","verification_uri_complete":"https://c/auth/device?user_code=ABCD-EFGH","interval":5,"expires_in":600}"#);
        assert_eq!(ds.user_code, "ABCD-EFGH");
        let tok: DeviceTokenResponse = rt(r#"{"user_token":"gu_x","expires_in":43200,"user":{"id":"usr_1","email":"ada@example.com","name":"Ada"}}"#);
        assert_eq!(tok.user.label(), "Ada (ada@example.com)");
        let me: MeResponse = rt(r#"{"user":{"id":"usr_1","email":"a@b","name":"A","groups":["g"]},"org":{"id":"o","slug":"s","name":"Acme"}}"#);
        assert_eq!(me.user.groups.as_deref(), Some(&["g".to_string()][..]));
        let hosts: HostsResponse = rt(r#"{"hosts":[{"id":"dev_h","name":"Studio","platform":"macos","tags":["staff-macs"],"online":true,"last_seen":"2026-11-25T10:00:00Z","permissions":{"control":true,"clipboard":"both","files":"to_host","audio":false},"approval":"required"}]}"#);
        assert_eq!(hosts.hosts[0].permissions.files, Direction::ToHost);
        let sr = serde_json::to_value(SessionRequest { host_id: "dev_h".into(), view_only: None }).unwrap();
        assert_eq!(sr, json!({"host_id":"dev_h"}));
        let s: SessionResponse = rt(r#"{"session_id":"ses_1","relay_url":"wss://glide.example.com/v1/relay/ses_1","ticket":"a.b","host":{"id":"dev_h","name":"Studio","public_key":"00"},"permissions":{"control":false,"clipboard":"off","files":"off","audio":true},"approval_required":true,"expires_at":"2026-11-25T10:02:00Z"}"#);
        assert!(s.approval_required && !s.permissions.control);
        let batch = AuditBatch {
            events: vec![AuditEvent { kind: audit_type::LOCAL_END.into(), ts: "2026-11-25T10:00:00Z".into(), session_id: Some("ses_1".into()), detail: json!({"by":"viewer_user"}) }],
        };
        assert_eq!(
            serde_json::to_value(&batch).unwrap(),
            json!({"events":[{"type":"session.local_end","ts":"2026-11-25T10:00:00Z","session_id":"ses_1","detail":{"by":"viewer_user"}}]})
        );
    }

    #[test]
    fn hub_frames() {
        let f: ServerFrame = serde_json::from_str(r#"{"type":"hello","device_id":"dev_1","settings":{"lan_mode":false},"server_time":"2026-11-25T10:00:00Z"}"#).unwrap();
        assert!(matches!(f, ServerFrame::Hello { ref settings, .. } if !settings.lan_mode));
        let f: ServerFrame = serde_json::from_str(
            r#"{"type":"session_offer","session_id":"ses_1","viewer":{"device_id":"dev_v","name":"PC","public_key":"aa"},"user":{"id":"usr_1","email":"a@example.com","name":"A"},"permissions":{"control":true,"clipboard":"both","files":"both","audio":true},"approval":"required","relay_url":"wss://c/v1/relay/ses_1","ticket":"t.s","expires_at":"2026-11-25T10:02:00Z"}"#,
        )
        .unwrap();
        match f {
            ServerFrame::SessionOffer(o) => {
                assert!(o.approval_required());
                assert_eq!(o.viewer.device_id, "dev_v");
            }
            other => panic!("{other:?}"),
        }
        let f: ServerFrame = serde_json::from_str(r#"{"type":"session_cancel","session_id":"ses_1","reason":"timeout"}"#).unwrap();
        assert_eq!(f, ServerFrame::SessionCancel { session_id: "ses_1".into(), reason: "timeout".into() });
        let f: ServerFrame = serde_json::from_str(r#"{"type":"settings","settings":{"allow_local_pairing":false}}"#).unwrap();
        assert!(matches!(f, ServerFrame::Settings { ref settings } if !settings.allow_local_pairing));
        let f: ServerFrame = serde_json::from_str(r#"{"type":"revoked","reason":"admin"}"#).unwrap();
        assert_eq!(f, ServerFrame::Revoked { reason: "admin".into() });
        let f: ServerFrame = serde_json::from_str(r#"{"type":"ping","t":1732530000000}"#).unwrap();
        assert_eq!(f, ServerFrame::Ping { t: json!(1732530000000u64) });
        let f: ServerFrame = serde_json::from_str(r#"{"type":"something_new","x":1}"#).unwrap();
        assert_eq!(f, ServerFrame::Unknown);
        // An offer with approval missing or unknown asks the user.
        let o: SessionOffer = serde_json::from_str(r#"{"session_id":"s","viewer":{},"relay_url":"u","ticket":"t"}"#).unwrap();
        assert!(o.approval_required());

        let out = |f: DeviceFrame| serde_json::to_value(f).unwrap();
        assert_eq!(out(DeviceFrame::SessionAnswer { session_id: "ses_1".into(), accept: true, reason: None }), json!({"type":"session_answer","session_id":"ses_1","accept":true}));
        assert_eq!(
            out(DeviceFrame::SessionAnswer { session_id: "ses_1".into(), accept: false, reason: Some(decline::BUSY.into()) }),
            json!({"type":"session_answer","session_id":"ses_1","accept":false,"reason":"busy"})
        );
        assert_eq!(out(DeviceFrame::SessionState { session_id: "ses_1".into(), state: "connected".into(), detail: None }), json!({"type":"session_state","session_id":"ses_1","state":"connected"}));
        assert_eq!(out(DeviceFrame::Pong { t: json!(5) }), json!({"type":"pong","t":5}));
    }

    #[test]
    fn relay_control() {
        assert_eq!(serde_json::from_str::<RelayControl>(r#"{"type":"waiting"}"#).unwrap(), RelayControl::Waiting);
        assert_eq!(serde_json::from_str::<RelayControl>(r#"{"type":"peer_joined"}"#).unwrap(), RelayControl::PeerJoined);
        assert_eq!(serde_json::from_str::<RelayControl>(r#"{"type":"peer_left"}"#).unwrap(), RelayControl::PeerLeft);
        assert_eq!(serde_json::from_str::<RelayControl>(r#"{"type":"later"}"#).unwrap(), RelayControl::Unknown);
        assert_eq!(close::describe(4005), "the session reached its time limit");
    }

    #[test]
    fn display_strings_are_cleaned() {
        // RLO / isolates / marks / C0 / C1 / DEL never reach a label.
        assert_eq!(clean_display("  Ada\u{202E}gnp.exe\u{202C} "), "Adagnp.exe");
        assert_eq!(clean_display("a\u{2066}b\u{2067}c\u{2068}d\u{2069}e\u{200E}f\u{200F}g\u{061C}h"), "abcdefgh");
        assert_eq!(clean_display("x\u{0}\u{7}\n\r\t\u{1b}[31my\u{7f}\u{85}\u{9b}z"), "x[31myz");
        assert_eq!(clean_display("Zoë 日本 😀"), "Zoë 日本 😀", "ordinary text is kept");
        for c in ['\u{202A}', '\u{202B}', '\u{202C}', '\u{202D}', '\u{202E}', '\u{2066}', '\u{2069}', '\u{200E}', '\u{200F}', '\u{0}', '\u{1f}', '\u{80}', '\u{9f}'] {
            assert!(unsafe_display_char(c), "{:04x}", c as u32);
        }
        // Every format character, separators, tags and variation selectors too.
        for c in [
            '\u{AD}', '\u{600}', '\u{6DD}', '\u{70F}', '\u{180B}', '\u{180E}', '\u{200B}', '\u{200C}', '\u{200D}', '\u{2028}', '\u{2029}', '\u{2060}', '\u{2061}', '\u{2064}',
            '\u{206A}', '\u{206F}', '\u{FE00}', '\u{FE0F}', '\u{FEFF}', '\u{FFF9}', '\u{FFFB}', '\u{110BD}', '\u{13430}', '\u{1BCA0}', '\u{1D173}', '\u{E0000}', '\u{E0001}',
            '\u{E0020}', '\u{E0041}', '\u{E007F}', '\u{E0100}', '\u{E01EF}',
        ] {
            assert!(unsafe_display_char(c), "{:04x}", c as u32);
        }
        for c in ['a', ' ', 'é', '日', '😀', '\u{2065}', '\u{FE10}', '\u{E0080}', '\u{E01F0}', '\u{2027}', '\u{202F}', '\u{FFFC}'] {
            assert!(!unsafe_display_char(c), "{:04x}", c as u32);
        }
        assert_eq!(clean_display("pay\u{200B}pal\u{FEFF}.com\u{AD}"), "paypal.com");
        assert_eq!(clean_display("ad\u{E0061}\u{E0064}min\u{FE0F}\u{E0100}"), "admin", "tags and variation selectors");
        assert_eq!(clean_display("Ada\u{2028}\u{2029}Lovelace"), "AdaLovelace", "separators are removed");
        // Whitespace runs collapse to one space; the ends are trimmed.
        assert_eq!(clean_display("  Ada \u{3000}\u{A0}  Lovelace\u{2003} "), "Ada Lovelace");
        assert_eq!(clean_display(" \u{200B} \u{2066} "), "");
        // Truncation on a char boundary with an ellipsis.
        assert_eq!(truncate_display("abcdef", 4), "abc…");
        assert_eq!(truncate_display("abcd", 4), "abcd");
        assert_eq!(truncate_display("日本語テキスト", 3), "日本…");

        let u: User = serde_json::from_str("{\"id\":\"usr_1\",\"email\":\"ada@example.com\\u202e\",\"name\":\"\\u202eecalevoL adA\\u0007\"}").unwrap();
        assert_eq!((u.name.as_str(), u.email.as_str()), ("ecalevoL adA", "ada@example.com"));
        assert_eq!(u.label(), "ecalevoL adA (ada@example.com)");
        // label() cleans even a User built by hand.
        let u = User { name: "\u{2067}Bo\u{2069}".into(), email: "\u{202d}".into(), ..Default::default() };
        assert_eq!(u.label(), "Bo");
        assert_eq!(User { name: "\u{202e}".into(), ..Default::default() }.label(), "an organization user");
        let u: User = serde_json::from_str(r#"{"id":"u","email":null,"name":null}"#).unwrap();
        assert_eq!(u.label(), "an organization user", "null display fields are empty");
        // Name and email are each capped at 64 characters.
        let long = User { name: "N".repeat(100), email: format!("{}@example.com", "e".repeat(80)), ..Default::default() };
        let l = long.label();
        assert_eq!(l, format!("{}… ({}…@example.com)", "N".repeat(63), "e".repeat(51)));
        // A long email never hides its real domain.
        let spoof = format!("it{}@yourcompany.com.evil.example", "x".repeat(60));
        let shown = User { email: spoof.clone(), ..Default::default() }.label();
        assert!(shown.ends_with("@yourcompany.com.evil.example"), "{shown}");
        assert_eq!(shown.chars().count(), LABEL_PART_MAX);
        assert_eq!(shown, format!("it{}…@yourcompany.com.evil.example", "x".repeat(32)));
        // The domain alone too long: its end (the registrable part) is kept.
        let long_domain = format!("it@{}.yourcompany.com.evil.example", "sub.".repeat(20));
        let shown = User { email: long_domain, ..Default::default() }.label();
        assert!(shown.starts_with("…@…") && shown.ends_with(".evil.example"), "{shown}");
        assert_eq!(shown.chars().count(), LABEL_PART_MAX);
        assert_eq!(truncate_email("it@yourcompany.com.evil.example", 20), "…@….com.evil.example");
        assert_eq!(truncate_email("ada@example.com", 64), "ada@example.com");
        assert_eq!(truncate_email("lovelace@example.com", 16), "lov…@example.com");
        assert_eq!(truncate_email("ab@example.com", 13), "…@example.com", "no room for the local part");
        assert_eq!(truncate_email("a@b@company.example", 16), "…@…mpany.example", "the last @ starts the domain");
        assert_eq!(truncate_email("no-at-sign-but-very-long", 10), "…very-long");
        assert_eq!(truncate_email("Zoë.日本@例え.テスト", 9), "Z…@例え.テスト", "char boundaries");
        let u: User = serde_json::from_str("{\"name\":\"Ada\\u200b\\u2028  Lovelace\",\"email\":\"ada\\ufeff@example.com\"}").unwrap();
        assert_eq!(u.label(), "Ada Lovelace (ada@example.com)");
        let d: DeviceInfo = serde_json::from_str("{\"name\":\"Front\\u00a0\\u00a0desk\\ufe0f\",\"tags\":[\"\\udb40\\udc01\"]}").unwrap();
        assert_eq!((d.name.as_str(), d.tags.len()), ("Front desk", 0), "tags-only tag is dropped");

        let d: DeviceInfo = serde_json::from_str("{\"name\":\"PC\\u202e1\",\"tags\":[\"lab\\u0000\",\"\\u2066\"],\"org\":{\"id\":\"o\",\"slug\":\"s\",\"name\":\"Acme\\u202e\"}}").unwrap();
        assert_eq!((d.name.as_str(), d.tags.clone(), d.org.name.as_str()), ("PC1", vec!["lab".to_string()], "Acme"));
        let h: HostsResponse = serde_json::from_str("{\"hosts\":[{\"id\":\"dev_h\",\"name\":\"Stu\\u202edio\"}]}").unwrap();
        assert_eq!(h.hosts[0].name, "Studio");
        let o: SessionOffer = serde_json::from_str("{\"session_id\":\"s\",\"viewer\":{\"name\":\"\\u202eCP\"},\"relay_url\":\"u\",\"ticket\":\"t\"}").unwrap();
        assert_eq!(o.viewer.name, "CP");
        let e: ErrorEnvelope = serde_json::from_str("{\"error\":{\"code\":\"x\",\"message\":\"bad\\u202e\\u001b[0m\"}}").unwrap();
        assert_eq!(e.error.message, "bad[0m");
        let f: ServerFrame = serde_json::from_str("{\"type\":\"revoked\",\"reason\":\"gone\\u202e\"}").unwrap();
        assert_eq!(f, ServerFrame::Revoked { reason: "gone".into() });
    }
}
