//! The Windows host's managed-mode agent (docs/ENTERPRISE.md §5.1, §5.3, §6.3–§6.6): enrollment,
//! hub, heartbeat, session offers (approval prompt, busy, policy), the relay bridge for accepted
//! sessions, revocation, settings and audit. The session itself runs in the existing host code
//! through `HostHooks::run_session`, which gets the loopback end of the bridge.

use super::api::{decline, DeviceFrame, HeartbeatRequest, Permissions, ServerFrame, SessionOffer, Settings, User};
use super::audit::AuditQueue;
use super::backoff::Backoff;
use super::bridge::{self, Bridge};
use super::client::CloudClient;
use super::enroll::{self, DeviceFacts, EnrollError};
use super::grants::{expired, parse_key, Grant, GrantStore};
use super::hub::{self, HubExit, HubHandler, HubLink};
use super::managed::ManagedConfig;
use super::settings::{app_version, version_ok};
use super::store::Store;
use super::transport::Http;
use crate::host::log;
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

/// The approval prompt declines by itself after this long (§6.4).
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(50);
/// Heartbeat once on the first hub connect, then this often (the hub itself shows presence).
pub const HEARTBEAT_EVERY: Duration = Duration::from_secs(6 * 3600);
pub const AUDIT_FLUSH_EVERY: Duration = Duration::from_secs(10);

/// When to send `POST /v1/device/heartbeat`.
#[derive(Default)]
pub struct Heartbeat {
    last: Mutex<Option<Instant>>,
}

impl Heartbeat {
    /// The hub connected: true the first time only.
    pub fn on_connect(&self) -> bool {
        let mut l = self.last.lock().unwrap();
        if l.is_none() {
            *l = Some(Instant::now());
            return true;
        }
        false
    }

    /// The periodic check: true every `HEARTBEAT_EVERY` after the first one.
    pub fn due(&self) -> bool {
        self.due_at(Instant::now())
    }

    pub fn due_at(&self, now: Instant) -> bool {
        let mut l = self.last.lock().unwrap();
        match *l {
            Some(t) if now.saturating_duration_since(t) >= HEARTBEAT_EVERY => {
                *l = Some(now);
                true
            }
            _ => false,
        }
    }
}

/// What the person at the host answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Approval {
    Accept,
    Decline,
}

/// The approval prompt's text and detail lines (§6.4, §6.7): names the user and email and the
/// viewer device (cleaned of control and bidirectional-override characters), and says "see and
/// control this PC" or "see this PC (view only)" according to `permissions.control`.
pub fn approval_text(o: &SessionOffer) -> (String, String) {
    let viewer = crate::host::trust::display_name(&super::api::clean_display(&o.viewer.name));
    let what = if o.permissions.control { "see and control this PC" } else { "see this PC (view only)" };
    (
        format!("{} from your organization asks to {what} (from “{viewer}”).\nAccept only if you expect this.", o.user.label()),
        format!("This session: {}.\nYou can end it at any time from the Glide Host icon (End session).", o.permissions.describe()),
    )
}

/// The host's UI for managed sessions.
pub trait HostUi: Send + Sync {
    /// The approval prompt naming the user and email (Decline default, Accept enabled after 1 s).
    /// Blocks; must return `Decline` soon after `cancel` becomes true (timeout or cancelled).
    fn approve(&self, offer: &SessionOffer, cancel: Arc<AtomicBool>) -> Approval;
    /// A managed session started or ended: refresh the "NAME (email) is connected" indicator.
    fn session_changed(&self) {}
    /// Something to tell the user (balloon / log).
    fn notice(&self, _text: &str) {}
}

/// The running managed session (the tray indicator, End session).
pub struct ActiveSession {
    pub session_id: String,
    pub user: User,
    pub viewer_name: String,
    pub permissions: Permissions,
    bridge: Bridge,
    link: Arc<HubLink>,
    ended: AtomicBool,
    authenticated: AtomicBool,
}

impl ActiveSession {
    /// "Ada Lovelace (ada@example.com) is connected".
    pub fn label(&self) -> String {
        format!("{} is connected", self.user.label())
    }

    /// The session may continue (not ended here, by the cloud or by the relay).
    pub fn live(&self) -> bool {
        !self.ended.load(Ordering::SeqCst) && !self.bridge.is_closed()
    }

    /// Called by the host once the viewer authenticated (Noise + grant): `session_state connected`.
    pub fn authenticated(&self) {
        if !self.authenticated.swap(true, Ordering::SeqCst) {
            let _ = self.link.send(&DeviceFrame::SessionState { session_id: self.session_id.clone(), state: "connected".into(), detail: None });
        }
    }

    fn end(&self) {
        self.ended.store(true, Ordering::SeqCst);
        self.bridge.close();
    }
}

/// Integration points with the host program.
pub struct HostHooks {
    /// Another session (LAN or managed) is running.
    pub busy: Box<dyn Fn() -> bool + Send + Sync>,
    /// Runs one accepted managed session on the loopback end of the bridge (handshake against the
    /// grant, then streaming) and returns when it ends. Must call `ActiveSession::authenticated`
    /// after the handshake and stop once `ActiveSession::live` turns false.
    pub run_session: Box<dyn Fn(TcpStream, Arc<ActiveSession>) + Send + Sync>,
    /// Org settings arrived or changed (LAN mode, local pairing).
    pub settings: Box<dyn Fn(&Settings) + Send + Sync>,
}

/// Managed mode as glide-host sees it: the agent once enrolled, and a status line.
pub struct HostCloud {
    pub agent: OnceLock<Arc<HostAgent>>,
    status: Arc<Mutex<String>>,
    pub grants: Arc<GrantStore>,
    stop: Arc<AtomicBool>,
}

impl HostCloud {
    pub fn status(&self) -> String {
        self.status.lock().unwrap().clone()
    }
    fn set_status(&self, s: &str) {
        log(&format!("cloud: {s}"));
        *self.status.lock().unwrap() = s.to_string();
    }
    pub fn active(&self) -> Option<Arc<ActiveSession>> {
        self.agent.get().and_then(|a| a.active())
    }
    /// End session (tray).
    pub fn end_session(&self) {
        if let Some(a) = self.agent.get() {
            a.end_active_locally();
        }
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(a) = self.agent.get() {
            a.link.close();
        }
    }
}

/// Starts managed mode in the background: enroll (retrying), then the hub, heartbeat and audit.
pub fn start(managed: ManagedConfig, store: Store, http: Arc<dyn Http>, facts: DeviceFacts, grants: Arc<GrantStore>, ui: Arc<dyn HostUi>, hooks: HostHooks) -> Arc<HostCloud> {
    let cloud = Arc::new(HostCloud { agent: OnceLock::new(), status: Arc::new(Mutex::new("Glide Cloud: enrolling…".into())), grants: grants.clone(), stop: Arc::new(AtomicBool::new(false)) });
    // The last known settings apply until the hub sends fresh ones.
    if let Ok(Some(e)) = store.load() {
        if e.cloud_url == managed.cloud_url {
            if let Some(s) = &e.settings {
                (hooks.settings)(s);
            }
        }
    }
    let c = cloud.clone();
    thread::Builder::new()
        .name("glide-cloud".into())
        .spawn(move || {
            let client0 = CloudClient::new(&managed.cloud_url, http);
            let sleep = hub::sleeper(c.stop.clone());
            let mut backoff = Backoff::enrollment(); // 5 s doubling to 10 min (§6.7)
            let enrollment = loop {
                match enroll::ensure(&managed, &store, &client0, &facts) {
                    Ok(e) => break e,
                    Err(EnrollError::Retry(e)) => {
                        c.set_status(&format!("Glide Cloud: can't enroll yet ({e}); retrying"));
                        if !sleep(backoff.next_delay()) {
                            return;
                        }
                    }
                    Err(EnrollError::Revoked) => {
                        // The last settings (applied above from the revocation record) stay.
                        let org = store.revoked_for(&managed.cloud_url).map(|r| r.org_name).filter(|n| !n.is_empty()).unwrap_or_else(|| "your organization".into());
                        c.set_status(&format!("Removed from {org}: this PC is no longer managed by Glide Cloud"));
                        return;
                    }
                    Err(e) => {
                        c.set_status(&format!("Glide Cloud: {e}"));
                        return;
                    }
                }
            };
            let org = if enrollment.org_name.is_empty() { "your organization".to_string() } else { enrollment.org_name.clone() };
            c.set_status(&format!("Managed by {org} (Glide Cloud)"));
            let agent = Arc::new(HostAgent {
                client: client0.with_device(&enrollment.device_token),
                store,
                grants,
                link: Arc::new(HubLink::default()),
                ui,
                hooks,
                audit: Arc::new(AuditQueue::default()),
                pending: Mutex::new(HashMap::new()),
                active: Mutex::new(None),
                accepting: AtomicBool::new(false),
                settings: Mutex::new(enrollment.settings.clone().unwrap_or_default()),
                stop: c.stop.clone(),
                os_version: facts.os_version.clone(),
                beat: Heartbeat::default(),
                status: c.status.clone(),
                org_name: Mutex::new(enrollment.org_name.clone()),
            });
            let _ = c.agent.set(agent.clone());
            agent.spawn_background();
            match hub::run(&agent.client, &AgentHub(agent.clone()), &agent.link, &c.stop, &sleep) {
                HubExit::Stopped => {}
                HubExit::Revoked(reason) => {
                    agent.revoked(&reason);
                    c.set_status(&format!("Removed from {}: this PC is no longer managed ({reason})", agent.org_label()));
                }
            }
        })
        .expect("spawn cloud thread");
    cloud
}

pub struct HostAgent {
    client: CloudClient,
    store: Store,
    grants: Arc<GrantStore>,
    link: Arc<HubLink>,
    ui: Arc<dyn HostUi>,
    hooks: HostHooks,
    pub audit: Arc<AuditQueue>,
    /// Cancel flags of offers waiting for an answer, by session id.
    pending: Mutex<HashMap<String, Arc<AtomicBool>>>,
    active: Mutex<Option<Arc<ActiveSession>>>,
    /// An offer is being accepted (between the answer and the session starting).
    accepting: AtomicBool,
    settings: Mutex<Settings>,
    stop: Arc<AtomicBool>,
    os_version: String,
    beat: Heartbeat,
    /// `HostCloud`'s status line ("Managed by Acme (Glide Cloud)").
    status: Arc<Mutex<String>>,
    /// The org's name (refreshed with `GET /v1/device` on each hub connection).
    org_name: Mutex<String>,
}

/// The hub's view of the agent.
pub struct AgentHub(pub Arc<HostAgent>);

impl HubHandler for AgentHub {
    fn frame(&self, f: ServerFrame, _link: &HubLink) {
        match f {
            ServerFrame::Hello { settings, .. } | ServerFrame::Settings { settings } => self.0.apply_settings(settings),
            ServerFrame::SessionOffer(o) => {
                // `frame` runs on the hub thread; the offer may wait for a person for 50 s.
                let me = self.0.clone();
                thread::spawn(move || me.handle_offer(*o));
            }
            ServerFrame::SessionCancel { session_id, reason } => self.0.cancel(&session_id, &reason),
            _ => {}
        }
    }
    fn connected(&self) {
        log("cloud: hub connected");
        // Refresh the device name, tags and org name (§6.7), off the hub thread.
        let me = self.0.clone();
        thread::spawn(move || me.refresh_device());
        if self.0.beat.on_connect() {
            let _ = self.0.heartbeat();
        }
    }
    fn disconnected(&self, why: &str) {
        log(&format!("cloud: hub disconnected ({why})"));
    }
}

impl HostAgent {
    fn spawn_background(self: &Arc<Self>) {
        let me = self.clone();
        thread::spawn(move || {
            let sleep = hub::sleeper(me.stop.clone());
            while sleep(AUDIT_FLUSH_EVERY) {
                let _ = me.audit.flush(&me.client);
                if me.beat.due() {
                    if let Err(e) = me.heartbeat() {
                        if e.is_unauthorized() {
                            // The hub sees the same 401 on its next upgrade and ends with Revoked.
                            me.link.close();
                        }
                    }
                }
            }
        });
    }

    /// The org's name, or "your organization".
    pub fn org_label(&self) -> String {
        let n = self.org_name.lock().unwrap().clone();
        if n.is_empty() {
            "your organization".into()
        } else {
            n
        }
    }

    /// `GET /v1/device`: refresh the device name, tags and org name (and the status line). A
    /// `401` means the device was revoked: the hub is closed, its reconnect sees the same `401`
    /// and ends with `Revoked`.
    pub fn refresh_device(&self) {
        let Ok(Some(mut e)) = self.store.load() else { return };
        if e.revoked {
            return;
        }
        match enroll::refresh_device(&self.store, &self.client, &mut e) {
            Ok(d) => {
                *self.org_name.lock().unwrap() = e.org_name.clone();
                let mut st = self.status.lock().unwrap();
                if st.starts_with("Managed by ") {
                    *st = format!("Managed by {} (Glide Cloud)", self.org_label());
                }
                drop(st);
                log(&format!("cloud: device “{}” (tags: {})", d.name, d.tags.join(", ")));
            }
            Err(err) if err.is_unauthorized() => {
                log("cloud: GET /v1/device was refused; this device was revoked");
                self.link.close();
            }
            Err(err) => log(&format!("cloud: GET /v1/device: {err}")),
        }
    }

    fn heartbeat(&self) -> Result<(), super::client::CloudError> {
        self.client.heartbeat(&HeartbeatRequest { app_version: app_version().into(), os_version: self.os_version.clone(), name: None })
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    fn apply_settings(&self, s: Settings) {
        self.audit.set_file_names(s.audit_file_names);
        enroll::remember_settings(&self.store, &s);
        (self.hooks.settings)(&s);
        *self.settings.lock().unwrap() = s;
    }

    pub fn active(&self) -> Option<Arc<ActiveSession>> {
        self.active.lock().unwrap().clone()
    }

    fn answer(&self, session_id: &str, accept: bool, reason: Option<&str>) -> bool {
        let r = self.link.send(&DeviceFrame::SessionAnswer { session_id: session_id.into(), accept, reason: reason.map(str::to_string) });
        if let Err(e) = &r {
            log(&format!("cloud: couldn't answer the offer for {session_id}: {e}"));
        }
        r.is_ok()
    }

    /// Decides an offer and, if accepted, runs the session (blocks until it ends).
    pub fn handle_offer(&self, o: SessionOffer) {
        if o.session_id.trim().is_empty() {
            log("cloud: ignoring an offer without a session_id (it can't be answered)");
            return;
        }
        let who = o.user.label();
        log(&format!("cloud: session {} requested by {who} from “{}”", o.session_id, o.viewer.name));
        if let Some(field) = o.missing_security_field() {
            log(&format!("cloud: declining {}: the offer has no {field}", o.session_id));
            self.answer(&o.session_id, false, Some(decline::POLICY));
            return;
        }
        let settings = self.settings();
        if !version_ok(app_version(), settings.min_app_version.as_deref()) {
            log(&format!("cloud: declining {}: this app is older than the org's minimum {:?}", o.session_id, settings.min_app_version));
            self.ui.notice(&super::settings::update_required(settings.min_app_version.as_deref().unwrap_or("")));
            self.answer(&o.session_id, false, Some(decline::POLICY));
            return;
        }
        if parse_key(&o.viewer.public_key).is_none() {
            log(&format!("cloud: declining {}: the offer has no valid viewer key", o.session_id));
            self.answer(&o.session_id, false, Some(decline::POLICY));
            return;
        }
        // The ticket only ever goes to this cloud's own relay for this session.
        if let Err(e) = super::client::check_relay_url(&self.client.base, &o.relay_url, &o.session_id) {
            log(&format!("cloud: declining {}: {e}", o.session_id));
            self.answer(&o.session_id, false, Some(decline::POLICY));
            return;
        }
        if expired(&o.expires_at, SystemTime::now()) {
            log(&format!("cloud: declining {}: the offer expired at {}", o.session_id, o.expires_at));
            self.answer(&o.session_id, false, Some(decline::TIMEOUT));
            return;
        }
        if (self.hooks.busy)() || self.active().is_some() || self.accepting.swap(true, Ordering::SeqCst) {
            log(&format!("cloud: declining {}: busy with another session", o.session_id));
            self.answer(&o.session_id, false, Some(decline::BUSY));
            return;
        }
        let _accepting = ResetOnDrop(&self.accepting);
        if o.approval_required() {
            let cancel = Arc::new(AtomicBool::new(false));
            let timed_out = Arc::new(AtomicBool::new(false));
            self.pending.lock().unwrap().insert(o.session_id.clone(), cancel.clone());
            {
                let (cancel, timed_out) = (cancel.clone(), timed_out.clone());
                thread::spawn(move || {
                    let end = Instant::now() + APPROVAL_TIMEOUT;
                    while Instant::now() < end && !cancel.load(Ordering::SeqCst) {
                        thread::sleep(Duration::from_millis(100));
                    }
                    if !cancel.swap(true, Ordering::SeqCst) {
                        timed_out.store(true, Ordering::SeqCst);
                    }
                });
            }
            let answer = self.ui.approve(&o, cancel.clone());
            let was_cancelled = cancel.swap(true, Ordering::SeqCst);
            self.pending.lock().unwrap().remove(&o.session_id);
            if timed_out.load(Ordering::SeqCst) {
                log(&format!("cloud: {} not answered in {} s; declined", o.session_id, APPROVAL_TIMEOUT.as_secs()));
                self.answer(&o.session_id, false, Some(decline::TIMEOUT));
                return;
            }
            if was_cancelled && answer == Approval::Decline {
                log(&format!("cloud: {} was cancelled", o.session_id));
                return; // session_cancel: nobody waits for an answer
            }
            if answer == Approval::Decline {
                log(&format!("cloud: {} declined here", o.session_id));
                self.answer(&o.session_id, false, Some(decline::DECLINED));
                return;
            }
        }
        // The grant's lifetime starts now, at acceptance (§6.7).
        let (now, wall) = (Instant::now(), SystemTime::now());
        if expired(&o.expires_at, wall) {
            log(&format!("cloud: declining {}: accepted after the offer expired at {}", o.session_id, o.expires_at));
            self.answer(&o.session_id, false, Some(decline::TIMEOUT));
            return;
        }
        let Some(grant) = Grant::from_offer(&o, now, wall) else {
            self.answer(&o.session_id, false, Some(decline::POLICY));
            return;
        };
        self.accept(o, grant, now);
    }

    fn accept(&self, o: SessionOffer, grant: Grant, now: Instant) {
        let sid = o.session_id.clone();
        self.grants.insert(grant.clone(), now);
        if !self.answer(&sid, true, None) {
            self.grants.cancel(&sid);
            return;
        }
        log(&format!("cloud: accepted {sid}; opening the relay"));
        let ws = match self.client.relay(&o.relay_url, &sid, &o.ticket) {
            Ok(ws) => ws,
            Err(e) => {
                log(&format!("cloud: relay for {sid}: {e}"));
                self.audit.client_error(Some(&sid), "relay_connect", &e.to_string());
                self.grants.cancel(&sid);
                return;
            }
        };
        let (stream, bridge) = match bridge::open(ws, &|| log(&format!("cloud: {sid}: waiting for the viewer on the relay"))) {
            Ok(x) => x,
            Err(e) => {
                log(&format!("cloud: relay for {sid}: {e}"));
                self.grants.cancel(&sid);
                return;
            }
        };
        let active = Arc::new(ActiveSession {
            session_id: sid.clone(),
            user: grant.user.clone(),
            viewer_name: grant.viewer_name.clone(),
            permissions: grant.permissions,
            bridge,
            link: self.link.clone(),
            ended: AtomicBool::new(false),
            authenticated: AtomicBool::new(false),
        });
        *self.active.lock().unwrap() = Some(active.clone());
        self.accepting.store(false, Ordering::SeqCst);
        self.ui.session_changed();
        (self.hooks.run_session)(stream, active.clone());
        active.end();
        active.bridge.join();
        self.grants.cancel(&sid);
        let detail = active.bridge.close_reason().map(|(c, r)| format!("{c} {r}").trim().to_string());
        let _ = self.link.send(&DeviceFrame::SessionState { session_id: sid.clone(), state: "ended".into(), detail });
        *self.active.lock().unwrap() = None;
        self.ui.session_changed();
        log(&format!("cloud: session {sid} ended"));
        let _ = self.audit.flush(&self.client);
    }

    fn cancel(&self, session_id: &str, reason: &str) {
        log(&format!("cloud: session {session_id} cancelled ({reason})"));
        if let Some(c) = self.pending.lock().unwrap().remove(session_id) {
            c.store(true, Ordering::SeqCst);
        }
        self.grants.cancel(session_id);
        if let Some(a) = self.active().filter(|a| a.session_id == session_id) {
            a.end();
        }
    }

    /// End session from the tray: audited as ended by the host user.
    pub fn end_active_locally(&self) {
        let Some(a) = self.active() else { return };
        log(&format!("cloud: ending session {} here", a.session_id));
        self.audit.local_end(&a.session_id, true);
        a.end();
        if let Err(e) = self.client.end_session(&a.session_id, false) {
            log(&format!("cloud: end session: {e}"));
        }
    }

    /// `revoked` frame or 401: delete the enrollment, end everything.
    fn revoked(&self, reason: &str) {
        log(&format!("cloud: this device was revoked ({reason}); deleting its credentials"));
        // Keep {cloud_url, revoked, settings}: the last org settings stay in force, across
        // restarts, until the managed CloudURL is removed or changes (§6.7).
        let org = self.store.load().ok().flatten().map(|e| e.org_name).unwrap_or_default();
        if let Err(e) = self.store.mark_revoked(&self.client.base, Some(self.settings()), &org) {
            log(&format!("cloud: {e}"));
        }
        self.grants.clear();
        for (_, c) in self.pending.lock().unwrap().drain() {
            c.store(true, Ordering::SeqCst);
        }
        if let Some(a) = self.active() {
            a.end();
        }
        self.stop.store(true, Ordering::SeqCst);
        self.ui.notice("This PC was removed from your organization's Glide Cloud.");
    }
}

struct ResetOnDrop<'a>(&'a AtomicBool);
impl Drop for ResetOnDrop<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::cloud::api::OfferViewer;
    use crate::cloud::client::fake::FakeHttp;
    use crate::cloud::store::{temp_dir, Plain};
    use crate::cloud::transport::fake::{pair, FakeWs};
    use crate::cloud::transport::{WebSocket, WsMsg};
    use std::io::{Read, Write};

    pub(crate) struct ScriptUi {
        pub answer: Option<Approval>,
        pub asked: Mutex<Vec<String>>,
        pub delay: Duration,
    }
    impl HostUi for ScriptUi {
        fn approve(&self, o: &SessionOffer, cancel: Arc<AtomicBool>) -> Approval {
            self.asked.lock().unwrap().push(o.user.label());
            thread::sleep(self.delay);
            loop {
                if cancel.load(Ordering::SeqCst) {
                    return Approval::Decline;
                }
                if let Some(a) = self.answer {
                    return a;
                }
                thread::sleep(Duration::from_millis(5));
            }
        }
    }

    pub(crate) fn offer(sid: &str, approval: &str) -> SessionOffer {
        SessionOffer {
            session_id: sid.into(),
            viewer: OfferViewer { device_id: "dev_v".into(), name: "Viewer PC".into(), public_key: "ab".repeat(32) },
            user: User { id: "usr_1".into(), email: "ada@example.com".into(), name: "Ada".into(), groups: None },
            permissions: Permissions { control: true, ..Default::default() },
            approval: approval.into(),
            relay_url: format!("wss://c.example.com/v1/relay/{sid}"),
            ticket: "tick.et".into(),
            expires_at: String::new(),
        }
    }

    struct Fixture {
        agent: Arc<HostAgent>,
        hub_server: Arc<FakeWs>,
        http: Arc<FakeHttp>,
        sessions: Arc<Mutex<Vec<String>>>,
        /// The grant's expiry as the session started.
        grant_expiry: Arc<Mutex<Option<Instant>>>,
        dir: std::path::PathBuf,
    }

    fn fixture(answer: Option<Approval>, busy: bool) -> Fixture {
        fixture_with(answer, busy, Duration::ZERO)
    }

    /// `delay`: how long the person takes to answer the prompt.
    fn fixture_with(answer: Option<Approval>, busy: bool, delay: Duration) -> Fixture {
        let http = Arc::new(FakeHttp::default());
        let dir = temp_dir("hostagent");
        let sessions = Arc::new(Mutex::new(Vec::new()));
        let s2 = sessions.clone();
        let grants = Arc::new(GrantStore::default());
        let grant_expiry = Arc::new(Mutex::new(None));
        let (g2, e2) = (grants.clone(), grant_expiry.clone());
        let agent = Arc::new(HostAgent {
            client: CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x"),
            store: Store::new(&dir, "cloud-host.dpapi", Arc::new(Plain)),
            grants,
            link: Arc::new(HubLink::default()),
            ui: Arc::new(ScriptUi { answer, asked: Mutex::new(vec![]), delay }),
            hooks: HostHooks {
                busy: Box::new(move || busy),
                run_session: Box::new(move |mut stream: TcpStream, a: Arc<ActiveSession>| {
                    *e2.lock().unwrap() = g2.expires_of(&a.session_id);
                    s2.lock().unwrap().push(a.session_id.clone());
                    a.authenticated();
                    let _ = stream.write_all(b"host-bytes");
                    let mut b = [0u8; 4];
                    let _ = stream.read_exact(&mut b);
                }),
                settings: Box::new(|_| {}),
            },
            audit: Arc::new(AuditQueue::default()),
            pending: Mutex::new(HashMap::new()),
            active: Mutex::new(None),
            accepting: AtomicBool::new(false),
            settings: Mutex::new(Settings::default()),
            stop: Arc::new(AtomicBool::new(false)),
            os_version: "10".into(),
            beat: Heartbeat::default(),
            status: Arc::new(Mutex::new("Managed by Acme (Glide Cloud)".into())),
            org_name: Mutex::new("Acme".into()),
        });
        let (hub_client, hub_server) = pair();
        agent.link.set_for_test(hub_client);
        Fixture { agent, hub_server, http, sessions, grant_expiry, dir }
    }

    fn answers(ws: &FakeWs) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        while let Ok(WsMsg::Text(t)) = recv_timeout(ws) {
            out.push(serde_json::from_str(&t).unwrap());
        }
        out
    }

    fn recv_timeout(ws: &FakeWs) -> std::io::Result<WsMsg> {
        // Everything the agent sent has been sent by the time we look.
        ws.try_recv().ok_or_else(|| std::io::ErrorKind::WouldBlock.into())
    }

    #[test]
    fn approval_none_accepts_and_runs_the_session_over_the_relay() {
        let f = fixture(None, false);
        let (relay_client, relay_server) = pair();
        f.http.sockets.lock().unwrap().push_back(Ok(relay_client.clone()));
        relay_server.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap();
        // The viewer answers once the host's bytes reached the relay (the session then ends;
        // ending earlier could drop bytes still in the loopback socket).
        let (rc, rs) = (relay_client.clone(), relay_server.clone());
        let replier = thread::spawn(move || {
            let t = Instant::now();
            while !rc.sent.lock().unwrap().iter().any(|m| matches!(m, WsMsg::Binary(b) if b == b"host-bytes")) && t.elapsed() < Duration::from_secs(10) {
                thread::sleep(Duration::from_millis(2));
            }
            rs.send(WsMsg::Binary(b"ping".to_vec())).unwrap();
        });
        f.agent.handle_offer(offer("ses_1", "none"));
        replier.join().unwrap();
        assert_eq!(*f.sessions.lock().unwrap(), vec!["ses_1"]);
        let a = answers(&f.hub_server);
        assert_eq!(a[0], serde_json::json!({"type":"session_answer","session_id":"ses_1","accept":true}));
        assert_eq!(a[1]["state"], "connected");
        assert_eq!(a[2]["state"], "ended");
        assert_eq!(f.http.ws_urls.lock().unwrap()[0].0, "wss://c.example.com/v1/relay/ses_1?ticket=tick.et");
        // What the session wrote went to the relay; the grant is gone either way.
        assert!(relay_client.sent.lock().unwrap().iter().any(|m| matches!(m, WsMsg::Binary(b) if b == b"host-bytes")));
        assert!(f.agent.grants.is_empty());
        assert!(f.agent.active().is_none());
        let _ = std::fs::remove_dir_all(&f.dir);
    }

    #[test]
    fn busy_declined_policy_timeout() {
        let f = fixture(None, true);
        f.agent.handle_offer(offer("ses_b", "none"));
        assert_eq!(answers(&f.hub_server)[0], serde_json::json!({"type":"session_answer","session_id":"ses_b","accept":false,"reason":"busy"}));

        let f = fixture(Some(Approval::Decline), false);
        f.agent.handle_offer(offer("ses_d", "required"));
        assert_eq!(answers(&f.hub_server)[0]["reason"], "declined");
        assert!(f.agent.grants.is_empty(), "no grant without acceptance");

        let f = fixture(None, false);
        *f.agent.settings.lock().unwrap() = Settings { min_app_version: Some("999.0".into()), ..Settings::default() };
        f.agent.handle_offer(offer("ses_p", "none"));
        assert_eq!(answers(&f.hub_server)[0]["reason"], "policy");

        let f = fixture(None, false);
        let mut o = offer("ses_k", "none");
        o.viewer.public_key = "zz".into();
        f.agent.handle_offer(o);
        assert_eq!(answers(&f.hub_server)[0]["reason"], "policy");
        assert!(f.sessions.lock().unwrap().is_empty());

        // A relay URL that isn't this cloud's own relay for the session: declined, ticket never sent.
        let f = fixture(None, false);
        let mut o = offer("ses_r", "none");
        o.relay_url = "wss://elsewhere.example.com/v1/relay/ses_r".into();
        f.agent.handle_offer(o);
        assert_eq!(answers(&f.hub_server)[0]["reason"], "policy");
        assert!(f.http.ws_urls.lock().unwrap().is_empty());
        assert!(f.agent.grants.is_empty());

        // Heartbeat: once on the first connect, then every 6 h.
        let hb = Heartbeat::default();
        assert!(!hb.due(), "nothing before the first connect");
        assert!(hb.on_connect());
        assert!(!hb.on_connect(), "reconnects don't heartbeat");
        assert!(!hb.due());
        assert!(hb.due_at(Instant::now() + HEARTBEAT_EVERY));
    }

    fn rfc3339_in(secs: i64) -> String {
        let now = SystemTime::now();
        let t = if secs >= 0 { now + Duration::from_secs(secs as u64) } else { now - Duration::from_secs((-secs) as u64) };
        crate::config::rfc3339_utc(t)
    }

    #[test]
    fn expired_offers_are_declined_before_prompting() {
        let f = fixture(Some(Approval::Accept), false);
        let mut o = offer("ses_e", "required");
        o.expires_at = rfc3339_in(-5);
        f.agent.handle_offer(o);
        assert_eq!(answers(&f.hub_server)[0], serde_json::json!({"type":"session_answer","session_id":"ses_e","accept":false,"reason":"timeout"}));
        // (The scripted prompt would have accepted: it was never shown.)
        assert!(f.sessions.lock().unwrap().is_empty() && f.agent.grants.is_empty());
        assert!(f.http.ws_urls.lock().unwrap().is_empty(), "the relay is never opened");
        // Busy still wins over prompting (no prompt, reason busy).
        let f = fixture(Some(Approval::Accept), true);
        f.agent.handle_offer(offer("ses_busy", "required"));
        assert_eq!(answers(&f.hub_server)[0]["reason"], "busy");
    }

    #[test]
    fn offers_missing_security_fields_are_declined_with_policy() {
        for strip in ["viewer.public_key", "relay_url", "ticket"] {
            let f = fixture(Some(Approval::Accept), false);
            let mut o = offer("ses_m", "none");
            match strip {
                "viewer.public_key" => o.viewer.public_key.clear(),
                "relay_url" => o.relay_url.clear(),
                _ => o.ticket.clear(),
            }
            f.agent.handle_offer(o);
            assert_eq!(answers(&f.hub_server), vec![serde_json::json!({"type":"session_answer","session_id":"ses_m","accept":false,"reason":"policy"})], "{strip}");
            assert!(f.http.ws_urls.lock().unwrap().is_empty() && f.agent.grants.is_empty());
        }
        // Without a session id there is nothing to answer.
        let f = fixture(Some(Approval::Accept), false);
        let mut o = offer("ses_x", "none");
        o.session_id.clear();
        f.agent.handle_offer(o);
        assert!(answers(&f.hub_server).is_empty());
        // From the wire: the hub decodes an offer without a ticket, and the agent declines it.
        let o: SessionOffer = serde_json::from_str(&format!(r#"{{"session_id":"ses_w","viewer":{{"public_key":"{}"}},"relay_url":"wss://c.example.com/v1/relay/ses_w"}}"#, "ab".repeat(32))).unwrap();
        let f = fixture(Some(Approval::Accept), false);
        f.agent.handle_offer(o);
        assert_eq!(answers(&f.hub_server)[0]["reason"], "policy");
    }

    #[test]
    fn grant_lifetime_starts_at_acceptance() {
        // The person takes 400 ms to accept; expires_at is far off, so the grant lives 120 s from
        // acceptance, not from the offer's arrival.
        let f = fixture_with(Some(Approval::Accept), false, Duration::from_millis(400));
        let (relay_client, relay_server) = pair();
        f.http.sockets.lock().unwrap().push_back(Ok(relay_client));
        relay_server.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap();
        relay_server.send(WsMsg::Binary(b"ping".to_vec())).unwrap();
        let mut o = offer("ses_g", "required");
        o.expires_at = rfc3339_in(3600);
        let arrived = Instant::now();
        f.agent.handle_offer(o);
        assert_eq!(*f.sessions.lock().unwrap(), vec!["ses_g"]);
        let exp = f.grant_expiry.lock().unwrap().expect("grant while the session starts");
        assert!(exp >= arrived + crate::cloud::grants::MAX_TTL + Duration::from_millis(400), "lifetime counted from acceptance");
        assert!(exp <= Instant::now() + crate::cloud::grants::MAX_TTL);

        // expires_at sooner than 120 s caps it.
        let f = fixture(None, false);
        let (relay_client, relay_server) = pair();
        f.http.sockets.lock().unwrap().push_back(Ok(relay_client));
        relay_server.send(WsMsg::Text(r#"{"type":"peer_joined"}"#.into())).unwrap();
        relay_server.send(WsMsg::Binary(b"ping".to_vec())).unwrap();
        let mut o = offer("ses_h", "none");
        o.expires_at = rfc3339_in(30);
        let t0 = Instant::now();
        f.agent.handle_offer(o);
        let exp = f.grant_expiry.lock().unwrap().unwrap();
        assert!(exp <= t0 + Duration::from_secs(31), "capped at expires_at");
    }

    #[test]
    fn hub_connection_refreshes_the_device() {
        let f = fixture(None, false);
        let enrolled = crate::cloud::store::Enrollment {
            cloud_url: "https://c.example.com".into(),
            device_id: "dev_h".into(),
            device_token: "gd_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
            org_name: "Acme".into(),
            ..Default::default()
        };
        f.agent.store.save(&enrolled).unwrap();
        f.http.on("GET /v1/device", 200, r#"{"device_id":"dev_h","kind":"host","name":"Reception PC","tags":["lobby"],"org":{"id":"o","slug":"acme","name":"Acme Europe"}}"#);
        f.http.on("POST /v1/device/heartbeat", 204, "");
        AgentHub(f.agent.clone()).connected();
        let t = Instant::now();
        while !f.agent.status.lock().unwrap().contains("Europe") && t.elapsed() < Duration::from_secs(5) {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(f.http.count("GET /v1/device"), 1);
        assert_eq!(*f.agent.status.lock().unwrap(), "Managed by Acme Europe (Glide Cloud)");
        let e = f.agent.store.load().unwrap().unwrap();
        assert_eq!((e.device_name.as_str(), e.tags.clone(), e.org_name.as_str()), ("Reception PC", vec!["lobby".to_string()], "Acme Europe"));
        // A 401 closes the hub (whose reconnect then ends with Revoked).
        f.http.routes.lock().unwrap().clear();
        f.http.on("GET /v1/device", 401, "");
        assert!(f.agent.link.is_connected());
        f.agent.refresh_device();
        assert!(!f.agent.link.is_connected());
        let _ = std::fs::remove_dir_all(&f.dir);
    }

    #[test]
    fn revocation_keeps_the_last_settings() {
        let f = fixture(None, false);
        let enrolled = crate::cloud::store::Enrollment {
            cloud_url: "https://c.example.com".into(),
            device_id: "dev_h".into(),
            device_token: "gd_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
            org_name: "Acme".into(),
            ..Default::default()
        };
        f.agent.store.save(&enrolled).unwrap();
        let lan_off = Settings { lan_mode: false, allow_local_pairing: false, ..Settings::default() };
        *f.agent.settings.lock().unwrap() = lan_off.clone();
        f.agent.revoked("admin");
        let r = f.agent.store.load().unwrap().unwrap();
        assert!(r.revoked && r.device_token.is_empty());
        assert_eq!((r.cloud_url.as_str(), r.settings, r.org_name.as_str()), ("https://c.example.com", Some(lan_off.clone()), "Acme"));
        // A restart with the same CloudURL: no enrollment, the record's settings apply.
        let managed = ManagedConfig { cloud_url: "https://c.example.com".into(), enrollment_token: Some("enr".into()), ..Default::default() };
        let applied = Arc::new(Mutex::new(Vec::new()));
        let a2 = applied.clone();
        let hooks = HostHooks { busy: Box::new(|| false), run_session: Box::new(|_, _| {}), settings: Box::new(move |s: &Settings| a2.lock().unwrap().push(s.clone())) };
        let ui: Arc<dyn HostUi> = Arc::new(ScriptUi { answer: None, asked: Mutex::new(vec![]), delay: Duration::ZERO });
        let facts = DeviceFacts { kind: enroll::Kind::Host, public_key: [1; 32], name: "PC".into(), os_version: "10".into(), app_version: "0.4.0".into() };
        let cloud = start(managed, f.agent.store.clone(), f.http.clone(), facts, Arc::new(GrantStore::default()), ui, hooks);
        let t = Instant::now();
        while !cloud.status().starts_with("Removed") && t.elapsed() < Duration::from_secs(5) {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(cloud.status(), "Removed from Acme: this PC is no longer managed by Glide Cloud");
        assert_eq!(*applied.lock().unwrap(), vec![lan_off]);
        assert_eq!(f.http.count("POST /v1/enroll"), 0, "never enrolls again at that CloudURL");
        let _ = std::fs::remove_dir_all(&f.dir);
    }

    #[test]
    fn approval_prompt_text() {
        let mut o = offer("ses_t", "required");
        let (text, detail) = approval_text(&o);
        assert!(text.starts_with("Ada (ada@example.com) from your organization asks to see and control this PC (from “Viewer PC”)."), "{text}");
        assert!(detail.starts_with("This session: can use the keyboard and mouse;"), "{detail}");
        o.permissions.control = false;
        o.user = User { name: "\u{202e}moc.live\u{202c}".into(), email: "x@example.com\u{7}".into(), ..Default::default() };
        o.viewer.name = "Evil\u{2066}PC\u{2069}\n".into();
        let (text, detail) = approval_text(&o);
        assert!(text.starts_with("moc.live (x@example.com) from your organization asks to see this PC (view only) (from “EvilPC”)."), "{text}");
        assert!(!text.contains("control"));
        assert!(detail.starts_with("This session: view only;"), "{detail}");
        assert!(!text.chars().any(|c| crate::cloud::api::unsafe_display_char(c) && c != '\n'));
    }

    #[test]
    fn cancel_closes_the_prompt_without_an_answer() {
        let f = fixture(None, false); // never answers by itself
        let a2 = f.agent.clone();
        let h = thread::spawn(move || a2.handle_offer(offer("ses_c", "required")));
        while f.agent.pending.lock().unwrap().is_empty() {
            thread::sleep(Duration::from_millis(5));
        }
        f.agent.cancel("ses_c", "viewer gave up");
        h.join().unwrap();
        assert!(answers(&f.hub_server).is_empty());
        assert!(f.sessions.lock().unwrap().is_empty());
    }

    impl HubLink {
        pub(crate) fn set_for_test(&self, ws: Arc<dyn WebSocket>) {
            self.set(Some(ws));
        }
    }
}
