//! Glide Cloud wire formats (docs/ENTERPRISE.md §6–§9): request and response bodies of the device
//! API, hub frames, relay control frames, org settings, session permissions and the error
//! envelope. JSON, with unknown fields ignored (§6). Where a field is missing the most restrictive
//! value is assumed for permissions; settings fall back to the documented defaults (§7).

use serde::{Deserialize, Serialize};

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
    pub slug: String,
    pub name: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct User {
    pub id: String,
    pub email: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<String>>,
}

impl User {
    /// "Ada Lovelace (ada@example.com)", or just the email.
    pub fn label(&self) -> String {
        let (n, e) = (self.name.trim(), self.email.trim());
        match (n.is_empty(), e.is_empty()) {
            (false, false) if n != e => format!("{n} ({e})"),
            (false, _) => n.to_string(),
            (true, false) => e.to_string(),
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
    pub name: String,
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
    pub name: String,
    pub platform: String,
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
        #[serde(default)]
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
}
