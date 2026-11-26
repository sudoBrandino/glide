//! The Windows viewer's managed-mode agent (docs/ENTERPRISE.md §5.1–§5.3): enrollment, the hub
//! (settings, revocation), user sign-in with the device authorization grant, the list of reachable
//! hosts, and starting a session: `POST /v1/sessions` → relay → bridge → a loopback stream that the
//! existing connection code runs with target `relay:<session_id>` and the cloud-named host key
//! pinned in memory only.

use super::api::{DeviceStartResponse, HeartbeatRequest, HostEntry, Permissions, ServerFrame, SessionRequest, Settings, User};
use super::audit::AuditQueue;
use super::backoff::Backoff;
use super::bridge::{self, Bridge};
use super::client::{CloudClient, CloudError};
use super::devauth::{self, SignInError};
use super::enroll::{self, DeviceFacts, EnrollError};
use super::grants::parse_key;
use super::hub::{self, HubExit, HubHandler, HubLink};
use super::managed::ManagedConfig;
use super::settings::{app_version, version_ok};
use super::store::{Enrollment, Store};
use super::transport::Http;
use crate::host::log;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

/// A managed session ready for the connection code.
pub struct ManagedSession {
    /// The app's end of the relay bridge: run the client handshake on it.
    pub stream: TcpStream,
    pub session_id: String,
    /// Pin for target `relay:<session_id>` (memory only).
    pub host_key: [u8; 32],
    pub host_name: String,
    pub permissions: Permissions,
    pub bridge: Bridge,
}

impl ManagedSession {
    pub fn target(&self) -> String {
        super::relay_target(&self.session_id)
    }
}

#[derive(Default)]
struct State {
    enrollment: Option<Enrollment>,
    /// Why there is no enrollment / the last cloud problem (status line).
    problem: Option<String>,
    hosts: Vec<HostEntry>,
    revoked: bool,
}

pub struct ViewerAgent {
    managed: ManagedConfig,
    store: Store,
    http: Arc<dyn Http>,
    state: Mutex<State>,
    pub audit: Arc<AuditQueue>,
    link: Arc<HubLink>,
    stop: Arc<AtomicBool>,
    /// Called (from any thread) when status, sign-in, hosts or settings change.
    on_change: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    heartbeat: super::host::Heartbeat,
    os_version: Mutex<String>,
}

fn now_s() -> i64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

impl ViewerAgent {
    pub fn new(managed: ManagedConfig, store: Store, http: Arc<dyn Http>) -> Arc<ViewerAgent> {
        let enrollment = store.load().ok().flatten().filter(|e| e.cloud_url == managed.cloud_url && e.plausible());
        Arc::new(ViewerAgent {
            managed,
            store,
            http,
            state: Mutex::new(State { enrollment, ..Default::default() }),
            audit: Arc::new(AuditQueue::default()),
            link: Arc::new(HubLink::default()),
            stop: Arc::new(AtomicBool::new(false)),
            on_change: Mutex::new(None),
            heartbeat: Default::default(),
            os_version: Mutex::new(String::new()),
        })
    }

    pub fn set_on_change(&self, f: Box<dyn Fn() + Send + Sync>) {
        *self.on_change.lock().unwrap() = Some(f);
    }

    fn changed(&self) {
        if let Some(f) = self.on_change.lock().unwrap().as_ref() {
            f();
        }
    }

    /// Enroll (retrying) and run the hub, heartbeat and audit flushing in the background.
    pub fn start(self: &Arc<Self>, facts: DeviceFacts) {
        *self.os_version.lock().unwrap() = facts.os_version.clone();
        let me = self.clone();
        thread::Builder::new()
            .name("glide-cloud".into())
            .spawn(move || {
                let sleep = hub::sleeper(me.stop.clone());
                let client0 = CloudClient::new(&me.managed.cloud_url, me.http.clone());
                let mut backoff = Backoff::default();
                let e = loop {
                    match enroll::ensure(&me.managed, &me.store, &client0, &facts) {
                        Ok(e) => break e,
                        Err(EnrollError::Retry(err)) => {
                            me.set_problem(Some(format!("Can't reach your organization's Glide service yet ({err})")));
                            if !sleep(backoff.next_delay()) {
                                return;
                            }
                        }
                        Err(EnrollError::Refused(err)) => {
                            me.set_problem(Some(format!("Your organization refused this PC's enrollment: {err}")));
                            return;
                        }
                        Err(err) => {
                            me.set_problem(Some(err.to_string()));
                            return;
                        }
                    }
                };
                {
                    let mut st = me.state.lock().unwrap();
                    // Keep a user token loaded at startup (same file).
                    st.enrollment = Some(e);
                    st.problem = None;
                }
                me.changed();
                let device_client = client0.with_device(&me.device_token().unwrap_or_default());
                {
                    let me = me.clone();
                    let c = device_client.clone();
                    let os = facts.os_version.clone();
                    thread::spawn(move || {
                        let sleep = hub::sleeper(me.stop.clone());
                        loop {
                            if me.heartbeat.due() {
                                if let Err(e) = c.heartbeat(&HeartbeatRequest { app_version: app_version().into(), os_version: os.clone(), name: None }) {
                                    if e.is_unauthorized() {
                                        me.link.close();
                                    }
                                }
                            }
                            let _ = me.audit.flush(&c);
                            if !sleep(super::host::AUDIT_FLUSH_EVERY) {
                                return;
                            }
                        }
                    });
                }
                if me.signed_in().is_some() {
                    let _ = me.refresh_hosts();
                }
                match hub::run(&device_client, &ViewerHub(me.clone()), &me.link, &me.stop, &sleep) {
                    HubExit::Stopped => {}
                    HubExit::Revoked(reason) => me.revoked(&reason),
                }
            })
            .expect("spawn cloud thread");
    }

    fn set_problem(&self, p: Option<String>) {
        if let Some(p) = &p {
            log(&format!("cloud: {p}"));
        }
        self.state.lock().unwrap().problem = p;
        self.changed();
    }

    fn device_token(&self) -> Option<String> {
        self.state.lock().unwrap().enrollment.as_ref().map(|e| e.device_token.clone())
    }

    fn client(&self) -> Option<CloudClient> {
        let st = self.state.lock().unwrap();
        let e = st.enrollment.as_ref()?;
        Some(CloudClient::new(&e.cloud_url, self.http.clone()).with_device(&e.device_token).with_user(e.live_user_token(now_s())))
    }

    /// The managed (normalized) CloudURL.
    pub fn cloud_url(&self) -> &str {
        &self.managed.cloud_url
    }

    pub fn enrolled(&self) -> bool {
        self.state.lock().unwrap().enrollment.is_some()
    }

    pub fn org_name(&self) -> String {
        self.state.lock().unwrap().enrollment.as_ref().map(|e| e.org_name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| "your organization".into())
    }

    /// The signed-in user, while the user token is live.
    pub fn signed_in(&self) -> Option<User> {
        let st = self.state.lock().unwrap();
        let e = st.enrollment.as_ref()?;
        e.live_user_token(now_s())?;
        Some(e.user.clone().unwrap_or_default())
    }

    pub fn settings(&self) -> Option<Settings> {
        self.state.lock().unwrap().enrollment.as_ref().and_then(|e| e.settings.clone())
    }

    pub fn local_lan_disabled(&self) -> bool {
        self.managed.disable_lan_mode
    }

    pub fn lan_allowed(&self) -> bool {
        super::settings::lan_allowed(self.settings().as_ref(), self.managed.disable_lan_mode)
    }

    pub fn local_pairing_allowed(&self) -> bool {
        super::settings::local_pairing_allowed(self.settings().as_ref(), self.managed.disable_lan_mode)
    }

    /// The org line for the UI ("Acme — signed in as Ada (ada@example.com)").
    pub fn status_line(&self) -> String {
        let (problem, revoked, enrolled) = {
            let st = self.state.lock().unwrap();
            (st.problem.clone(), st.revoked, st.enrollment.is_some())
        };
        if revoked {
            return "This PC was removed from your organization's Glide Cloud.".into();
        }
        if !enrolled {
            return problem.unwrap_or_else(|| "Connecting to your organization's Glide service…".into());
        }
        let org = self.org_name();
        if let Some(min) = self.settings().and_then(|s| s.min_app_version).filter(|m| !version_ok(app_version(), Some(m))) {
            return super::settings::update_required(&min);
        }
        match self.signed_in() {
            Some(u) => format!("{org} — signed in as {}", u.label()),
            None => format!("{org} — not signed in"),
        }
    }

    pub fn hosts(&self) -> Vec<HostEntry> {
        self.state.lock().unwrap().hosts.clone()
    }

    /// Step 1 of sign-in (§5.2): the code to show and the page to open.
    pub fn begin_sign_in(&self) -> Result<DeviceStartResponse, String> {
        let c = self.client().ok_or_else(|| self.status_line())?;
        c.device_start().map_err(|e| e.user_message())
    }

    /// Step 2: poll until approved; stores the user token.
    pub fn finish_sign_in(&self, start: &DeviceStartResponse, cancel: &AtomicBool) -> Result<User, SignInError> {
        let c = self.client().ok_or_else(|| SignInError::Failed("not enrolled".into()))?;
        let stop = Arc::new(AtomicBool::new(false));
        let t = devauth::poll(&c, start, cancel, &|d| {
            let end = Instant::now() + d;
            while Instant::now() < end {
                if cancel.load(Ordering::SeqCst) || stop.load(Ordering::SeqCst) {
                    return false;
                }
                thread::sleep(Duration::from_millis(100));
            }
            true
        })?;
        let exp = crate::config::rfc3339_utc(SystemTime::now() + Duration::from_secs(t.expires_in));
        let user = t.user.clone();
        let saved = {
            let mut st = self.state.lock().unwrap();
            let Some(e) = st.enrollment.as_mut() else { return Err(SignInError::Failed("not enrolled".into())) };
            e.user_token = Some(t.user_token);
            e.user_token_expires = Some(exp);
            e.user = Some(user.clone());
            e.clone()
        };
        if let Err(e) = self.store.save(&saved) {
            log(&format!("cloud: {e} (signed in for this run only)"));
        }
        log(&format!("cloud: signed in as {}", user.label()));
        self.changed();
        let _ = self.refresh_hosts();
        Ok(user)
    }

    /// Signs out (revokes the user token at the cloud, best effort) and forgets it here.
    pub fn sign_out(&self) {
        if let Some(c) = self.client() {
            if let Err(e) = c.signout() {
                log(&format!("cloud: sign-out: {e}"));
            }
        }
        self.forget_user();
    }

    fn forget_user(&self) {
        let saved = {
            let mut st = self.state.lock().unwrap();
            st.hosts.clear();
            st.enrollment.as_mut().map(|e| {
                e.clear_user();
                e.clone()
            })
        };
        if let Some(e) = saved {
            if let Err(err) = self.store.save(&e) {
                log(&format!("cloud: {err}"));
            }
        }
        self.changed();
    }

    /// A user call answered 401: the user token is no longer good (expired or signed out
    /// elsewhere). If the device token is refused too, the device was revoked.
    fn on_user_error(&self, e: &CloudError) {
        if !e.is_unauthorized() {
            return;
        }
        log("cloud: the user token was refused; signing out here");
        self.forget_user();
        if let Some(c) = self.client() {
            if c.device().err().is_some_and(|e| e.is_unauthorized()) {
                self.revoked("device token refused");
            }
        }
    }

    pub fn refresh_hosts(&self) -> Result<Vec<HostEntry>, String> {
        let c = self.client().ok_or_else(|| self.status_line())?;
        if self.signed_in().is_none() {
            return Err("Sign in to your organization to see its computers.".into());
        }
        match c.hosts() {
            Ok(h) => {
                let mut hosts = h.hosts;
                hosts.sort_by_key(|h| (!h.online, h.name.to_lowercase()));
                self.state.lock().unwrap().hosts = hosts.clone();
                self.changed();
                Ok(hosts)
            }
            Err(e) => {
                self.on_user_error(&e);
                Err(e.user_message())
            }
        }
    }

    /// Requests a session with `host_id` and opens the relay (blocks: up to 60 s for the host's
    /// approval, then up to 70 s for it to join). `status` gets progress lines.
    pub fn connect(&self, host_id: &str, host_label: &str, status: &dyn Fn(String)) -> Result<ManagedSession, String> {
        if let Some(min) = self.settings().and_then(|s| s.min_app_version).filter(|m| !version_ok(app_version(), Some(m))) {
            return Err(super::settings::update_required(&min));
        }
        let c = self.client().ok_or_else(|| self.status_line())?;
        if self.signed_in().is_none() {
            return Err("Sign in to your organization first.".into());
        }
        let approval = self.hosts().iter().find(|h| h.id == host_id).is_some_and(|h| h.approval == "required");
        status(if approval { format!("Waiting for {host_label} to approve…") } else { format!("Connecting to {host_label}…") });
        let r = c.create_session(&SessionRequest { host_id: host_id.into(), view_only: None }).map_err(|e| {
            self.on_user_error(&e);
            e.user_message()
        })?;
        if let Some(field) = r.missing_security_field() {
            // Rejected (§6.7); a session the cloud did create is ended right away.
            log(&format!("cloud: the session answer has no {field}; refusing it"));
            if !r.session_id.trim().is_empty() {
                self.end_session(&c, &r.session_id);
            }
            return Err(format!("Glide Cloud sent an incomplete session answer (no {field})"));
        }
        let Some(host_key) = parse_key(&r.host.public_key) else {
            self.end_session(&c, &r.session_id);
            return Err("Glide Cloud sent an invalid host key".into());
        };
        let host_name = if r.host.name.trim().is_empty() { host_label.to_string() } else { r.host.name.clone() };
        status(format!("Connecting to {host_name} through Glide Cloud…"));
        let ws = c.relay(&r.relay_url, &r.session_id, &r.ticket).map_err(|e| {
            self.audit.client_error(Some(&r.session_id), "relay_connect", &e.to_string());
            format!("Can't open the relay: {e}")
        })?;
        let (stream, bridge) = bridge::open(ws, &|| status(format!("Waiting for {host_name} to join…"))).map_err(|e| format!("{e}"))?;
        Ok(ManagedSession { stream, session_id: r.session_id, host_key, host_name, permissions: r.permissions, bridge })
    }

    /// `POST /v1/sessions/{id}/end` (idempotent; `404`, a session already gone, is fine).
    fn end_session(&self, c: &CloudClient, session_id: &str) {
        match c.end_session(session_id, true) {
            Ok(()) => {}
            Err(e) if e.status() == Some(404) => {}
            Err(e) => log(&format!("cloud: end session {session_id}: {e}")),
        }
    }

    /// The session ended. `by_user`: this viewer's user ended it (audited, and the cloud told).
    pub fn ended(&self, session_id: &str, by_user: bool) {
        if by_user {
            self.audit.local_end(session_id, false);
            if let Some(c) = self.client() {
                if let Err(e) = c.end_session(session_id, true) {
                    log(&format!("cloud: end session: {e}"));
                }
            }
        }
        if let Some(c) = self.client() {
            let _ = self.audit.flush(&c);
        }
    }

    fn apply_settings(&self, s: Settings) {
        self.audit.set_file_names(s.audit_file_names);
        enroll::remember_settings(&self.store, &s);
        if let Some(e) = self.state.lock().unwrap().enrollment.as_mut() {
            e.settings = Some(s);
        }
        self.changed();
    }

    fn revoked(&self, reason: &str) {
        log(&format!("cloud: this device was revoked ({reason}); deleting the enrollment"));
        if let Err(e) = self.store.wipe() {
            log(&format!("cloud: {e}"));
        }
        {
            let mut st = self.state.lock().unwrap();
            st.enrollment = None;
            st.hosts.clear();
            st.revoked = true;
        }
        self.stop.store(true, Ordering::SeqCst);
        self.link.close();
        self.changed();
    }

    pub fn is_revoked(&self) -> bool {
        self.state.lock().unwrap().revoked
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        self.link.close();
    }
}

/// Row id prefix of organization hosts in the Connections window.
pub const ROW_PREFIX: &str = "org:";

/// The organization's hosts as Connections-window rows (group "Organization: NAME"), filtered by
/// name or tag like the saved connections. `supported` = online (Connect is possible).
pub fn host_rows(hosts: &[HostEntry], org: &str, filter: &str, now: SystemTime) -> Vec<crate::connections::Row> {
    let f = filter.trim().to_lowercase();
    hosts
        .iter()
        .filter(|h| f.is_empty() || h.name.to_lowercase().contains(&f) || h.tags.iter().any(|t| t.to_lowercase().contains(&f)) || "organization".contains(&f))
        .map(|h| {
            let mut status = if h.online { "Online".to_string() } else { "Offline".to_string() };
            if h.approval == "required" {
                status.push_str(" · asks for approval");
            }
            if !h.permissions.control {
                status.push_str(" · view only");
            }
            let last_used = match (h.online, h.last_seen.as_deref()) {
                (true, _) => "Now".to_string(),
                (false, Some(t)) => match super::grants::parse_time(t) {
                    Some(s) => crate::connections::relative_time(&crate::config::rfc3339_utc(SystemTime::UNIX_EPOCH + Duration::from_secs(s.max(0) as u64)), now),
                    None => "—".into(),
                },
                (false, None) => "—".into(),
            };
            crate::connections::Row {
                id: format!("{ROW_PREFIX}{}", h.id),
                name: h.name.clone(),
                address: if h.platform == "macos" { "Mac · Glide Cloud".into() } else { "PC · Glide Cloud".into() },
                group: format!("Organization: {org}"),
                status,
                paired: false,
                last_used,
                active: false,
                favorite: false,
                supported: h.online,
            }
        })
        .collect()
}

struct ViewerHub(Arc<ViewerAgent>);

impl HubHandler for ViewerHub {
    fn frame(&self, f: ServerFrame, _link: &HubLink) {
        match f {
            ServerFrame::Hello { settings, .. } | ServerFrame::Settings { settings } => self.0.apply_settings(settings),
            _ => {}
        }
    }
    fn connected(&self) {
        log("cloud: hub connected");
        if self.0.heartbeat.on_connect() {
            if let Some(c) = self.0.client() {
                let os = self.0.os_version.lock().unwrap().clone();
                let _ = c.heartbeat(&HeartbeatRequest { app_version: app_version().into(), os_version: os, name: None });
            }
        }
    }
    fn disconnected(&self, why: &str) {
        log(&format!("cloud: hub disconnected ({why})"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::client::fake::FakeHttp;
    use crate::cloud::store::{temp_dir, Plain};
    use crate::cloud::transport::fake::pair;
    use crate::cloud::transport::{WebSocket, WsMsg};
    use std::io::{Read, Write};

    fn agent(http: Arc<FakeHttp>, user: bool) -> (Arc<ViewerAgent>, std::path::PathBuf) {
        let dir = temp_dir("viewer");
        let store = Store::new(&dir, "cloud-viewer.dpapi", Arc::new(Plain));
        let mut e = Enrollment {
            cloud_url: "https://c.example.com".into(),
            org_id: "org_1".into(),
            device_id: "dev_v".into(),
            device_token: "gd_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
            enrolled_at: "2026-11-25T10:00:00Z".into(),
            org_name: "Acme".into(),
            ..Default::default()
        };
        if user {
            e.user_token = Some("gu_tok".into());
            e.user_token_expires = Some(crate::config::rfc3339_utc(SystemTime::now() + Duration::from_secs(3600)));
            e.user = Some(User { id: "usr_1".into(), email: "ada@example.com".into(), name: "Ada".into(), groups: None });
        }
        store.save(&e).unwrap();
        let m = ManagedConfig { cloud_url: "https://c.example.com".into(), ..Default::default() };
        (ViewerAgent::new(m, store, http), dir)
    }

    #[test]
    fn rows_for_the_connections_window() {
        let hosts = vec![
            HostEntry { id: "dev_a".into(), name: "Studio".into(), platform: "macos".into(), online: true, approval: "required".into(), permissions: Permissions { control: true, ..Default::default() }, ..Default::default() },
            HostEntry { id: "dev_b".into(), name: "Lab PC".into(), platform: "windows".into(), tags: vec!["lab".into()], online: false, last_seen: Some("2026-11-25T09:00:00.000Z".into()), approval: "none".into(), ..Default::default() },
        ];
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(crate::connections::parse_rfc3339("2026-11-25T10:00:00Z").unwrap() as u64);
        let r = host_rows(&hosts, "Acme", "", now);
        assert_eq!(r[0].id, "org:dev_a");
        assert_eq!((r[0].status.as_str(), r[0].supported, r[0].group.as_str()), ("Online · asks for approval", true, "Organization: Acme"));
        assert_eq!((r[1].status.as_str(), r[1].supported, r[1].address.as_str()), ("Offline · view only", false, "PC · Glide Cloud"));
        assert_eq!(r[1].last_used, "1 hour ago");
        assert_eq!(host_rows(&hosts, "Acme", "lab", now).len(), 1);
        assert!(host_rows(&hosts, "Acme", "zzz", now).is_empty());
    }

    #[test]
    fn status_and_settings() {
        let http = Arc::new(FakeHttp::default());
        let (a, dir) = agent(http.clone(), true);
        assert_eq!(a.status_line(), "Acme — signed in as Ada (ada@example.com)");
        assert!(a.lan_allowed() && a.local_pairing_allowed());
        a.apply_settings(Settings { lan_mode: false, ..Settings::default() });
        assert!(!a.lan_allowed() && !a.local_pairing_allowed());
        a.apply_settings(Settings { min_app_version: Some("999".into()), ..Settings::default() });
        assert!(a.status_line().starts_with("Update required"));
        assert!(a.connect("dev_h", "Studio", &|_| {}).err().unwrap().starts_with("Update required"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn sign_in_out_and_expired_token() {
        let http = Arc::new(FakeHttp::default());
        let (a, dir) = agent(http.clone(), false);
        assert_eq!(a.status_line(), "Acme — not signed in");
        assert!(a.refresh_hosts().is_err());
        http.on("POST /v1/auth/device/start", 200, r#"{"device_code":"dc","user_code":"WXYZ-1234","verification_uri":"https://c.example.com/auth/device","verification_uri_complete":"https://c.example.com/auth/device?user_code=WXYZ-1234","interval":1,"expires_in":600}"#);
        http.on("POST /v1/auth/device/token", 200, r#"{"user_token":"gu_new","expires_in":3600,"user":{"id":"usr_2","email":"bo@example.com","name":"Bo"}}"#);
        http.on("GET /v1/hosts", 200, r#"{"hosts":[{"id":"dev_b","name":"b","online":false},{"id":"dev_a","name":"A","online":true,"approval":"required"}]}"#);
        let s = a.begin_sign_in().unwrap();
        assert_eq!(s.user_code, "WXYZ-1234");
        let u = a.finish_sign_in(&s, &AtomicBool::new(false)).unwrap();
        assert_eq!(u.email, "bo@example.com");
        assert!(a.status_line().ends_with("signed in as Bo (bo@example.com)"));
        assert_eq!(a.hosts().iter().map(|h| h.id.as_str()).collect::<Vec<_>>(), vec!["dev_a", "dev_b"], "online first");
        // The token survives a restart (same file).
        assert_eq!(a.store.load().unwrap().unwrap().user_token.as_deref(), Some("gu_new"));
        // A 401 on a user call signs out (the device itself is fine).
        http.routes.lock().unwrap().remove("GET /v1/hosts");
        http.on("GET /v1/hosts", 401, "");
        http.on("GET /v1/device", 200, r#"{"device_id":"dev_v"}"#);
        assert!(a.refresh_hosts().is_err());
        assert!(a.signed_in().is_none());
        assert!(a.enrolled());
        // Sign-out when signed in revokes the token at the cloud.
        a.finish_sign_in(&s, &AtomicBool::new(false)).unwrap();
        http.on("POST /v1/auth/signout", 204, "");
        a.sign_out();
        assert!(a.signed_in().is_none());
        assert_eq!(http.count("POST /v1/auth/signout"), 1);
        assert!(a.store.load().unwrap().unwrap().user_token.is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn revoked_device_wipes_enrollment() {
        let http = Arc::new(FakeHttp::default());
        let (a, dir) = agent(http.clone(), true);
        http.on("GET /v1/hosts", 401, "");
        http.on("GET /v1/device", 401, "");
        assert!(a.refresh_hosts().is_err());
        assert!(a.is_revoked() && !a.enrolled());
        assert_eq!(a.store.load(), Ok(None));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn connect_through_the_relay() {
        let http = Arc::new(FakeHttp::default());
        let (a, dir) = agent(http.clone(), true);
        http.on(
            "POST /v1/sessions",
            201,
            &format!(
                r#"{{"session_id":"ses_9","relay_url":"wss://c.example.com/v1/relay/ses_9","ticket":"tk","host":{{"id":"dev_h","name":"Studio","public_key":"{}"}},"permissions":{{"control":true,"clipboard":"to_viewer","files":"off","audio":false}},"approval_required":false,"expires_at":"2026-11-25T10:02:00Z"}}"#,
                "cd".repeat(32)
            ),
        );
        let (relay_client, relay_server) = pair();
        http.sockets.lock().unwrap().push_back(Ok(relay_client.clone()));
        relay_server.send(WsMsg::Text(r#"{"type":"waiting"}"#.into())).unwrap();
        relay_server.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap();
        let lines = Mutex::new(Vec::new());
        let mut s = a.connect("dev_h", "Studio", &|l| lines.lock().unwrap().push(l)).unwrap();
        assert_eq!((s.session_id.as_str(), s.host_key, s.target()), ("ses_9", [0xcd; 32], "relay:ses_9".to_string()));
        assert_eq!(s.permissions.clipboard, crate::cloud::Direction::ToViewer);
        let l = lines.lock().unwrap().clone();
        assert_eq!(l[0], "Connecting to Studio…");
        assert!(l.contains(&"Waiting for Studio to join…".to_string()));
        s.stream.write_all(b"GLD2").unwrap();
        relay_server.send(WsMsg::Binary(b"back".to_vec())).unwrap();
        let mut b = [0u8; 4];
        s.stream.read_exact(&mut b).unwrap();
        assert_eq!(&b, b"back");
        let body: serde_json::Value = serde_json::from_slice(http.requests.lock().unwrap()[0].body.as_ref().unwrap()).unwrap();
        assert_eq!(body, serde_json::json!({"host_id":"dev_h"}));
        s.bridge.close();
        // Ended by the user: audited and told to the cloud.
        http.on("POST /v1/sessions/ses_9/end", 204, "");
        http.on("POST /v1/audit", 202, "");
        a.ended("ses_9", true);
        assert_eq!(http.count("POST /v1/sessions/ses_9/end"), 1);
        let audit = http.requests.lock().unwrap().iter().find(|r| r.url.ends_with("/v1/audit")).cloned().unwrap();
        let v: serde_json::Value = serde_json::from_slice(audit.body.as_ref().unwrap()).unwrap();
        assert_eq!(v["events"][0]["type"], "session.local_end");
        assert_eq!(v["events"][0]["detail"]["by"], "viewer_user");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn approval_status_and_errors() {
        let http = Arc::new(FakeHttp::default());
        let (a, dir) = agent(http.clone(), true);
        a.state.lock().unwrap().hosts = vec![HostEntry { id: "dev_h".into(), name: "Studio".into(), approval: "required".into(), ..Default::default() }];
        http.on("POST /v1/sessions", 403, r#"{"error":{"code":"denied_by_host","message":"x"}}"#);
        let lines = Mutex::new(Vec::new());
        let e = a.connect("dev_h", "Studio", &|l| lines.lock().unwrap().push(l)).err().unwrap();
        assert_eq!(lines.lock().unwrap()[0], "Waiting for Studio to approve…");
        assert_eq!(e, "The person at that computer declined the request");
        // A relay URL that isn't this cloud's is refused before connecting.
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/sessions", 201, &format!(r#"{{"session_id":"ses_1","relay_url":"wss://evil.example.com/v1/relay/ses_1","ticket":"t","host":{{"id":"h","name":"S","public_key":"{}"}}}}"#, "00".repeat(32)));
        assert!(a.connect("dev_h", "Studio", &|_| {}).is_err());
        assert!(http.ws_urls.lock().unwrap().is_empty());
        // A session answer missing a security field is rejected, and the session ended at once.
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/sessions", 201, r#"{"session_id":"ses_2","relay_url":"wss://c.example.com/v1/relay/ses_2","host":{"id":"h","name":"S","public_key":"00"}}"#);
        http.on("POST /v1/sessions/ses_2/end", 404, r#"{"error":{"code":"not_found","message":"x"}}"#);
        let e = a.connect("dev_h", "Studio", &|_| {}).err().unwrap();
        assert!(e.contains("no ticket"), "{e}");
        assert_eq!(http.count("POST /v1/sessions/ses_2/end"), 1);
        assert!(http.ws_urls.lock().unwrap().is_empty());
        // Without even a session id there is nothing to end.
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/sessions", 201, r#"{"relay_url":"x"}"#);
        assert!(a.connect("dev_h", "Studio", &|_| {}).err().unwrap().contains("no session_id"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
