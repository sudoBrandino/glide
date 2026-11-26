//! The viewer's managed mode (Glide Cloud, docs/ENTERPRISE.md) on the Windows side: the agent,
//! starting a session from the Connections window (the request, "Waiting for NAME to approve…",
//! the relay), handing the bridged stream to the session thread, the organization sign-in dialog
//! (device authorization grant) and sign-out, audit hooks for clipboard and file transfers.
//!
//! The session thread (`app`) asks `take_pending` / `status` / `lan_allowed` at the top of its
//! loop: a managed session runs once (never redialed), with the cloud-named host key pinned in
//! memory for target `relay:<session_id>` and the session's permissions enforced by
//! `net::Connection::restrict`.

use crate::cloud::api::{HostEntry, Permissions};
use crate::cloud::audit::AuditQueue;
use crate::cloud::devauth::SignInError;
use crate::cloud::viewer::{ManagedSession, ViewerAgent};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::*;

/// How long a failure or "session ended" line stays in the status before the normal loop resumes.
const NOTE_SHOWN: Duration = Duration::from_secs(8);

static AGENT: OnceLock<Arc<ViewerAgent>> = OnceLock::new();
static STATE: Mutex<State> = Mutex::new(State { connecting: None, note: None, pending: None, active: None });

struct State {
    /// A request is in progress: the status line ("Waiting for Studio to approve…").
    connecting: Option<String>,
    /// A recent failure or end of a managed session, shown for `NOTE_SHOWN`.
    note: Option<(String, Instant)>,
    /// A bridged session waiting for the session thread.
    pending: Option<ManagedSession>,
    active: Option<Active>,
}

/// The running managed session.
#[derive(Clone, Debug)]
pub struct Active {
    pub session_id: String,
    pub host_name: String,
    pub permissions: Permissions,
}

pub fn init(agent: Option<Arc<ViewerAgent>>) {
    if let Some(a) = agent {
        let _ = AGENT.set(a);
    }
}

pub fn agent() -> Option<&'static Arc<ViewerAgent>> {
    AGENT.get()
}

pub fn managed() -> bool {
    AGENT.get().is_some()
}

/// LAN dialing and listening are allowed (org `lan_mode`, local `DisableLANMode`).
pub fn lan_allowed() -> bool {
    AGENT.get().is_none_or(|a| a.lan_allowed()) && !LOCAL_LAN_OFF.load(Ordering::Relaxed)
}

/// A new LAN host may be paired (org `allow_local_pairing`, and LAN mode).
pub fn local_pairing_allowed() -> bool {
    lan_allowed() && AGENT.get().is_none_or(|a| a.local_pairing_allowed())
}

/// `DisableLANMode` without a cloud (policy only).
static LOCAL_LAN_OFF: AtomicBool = AtomicBool::new(false);

pub fn set_local_lan_off(off: bool) {
    LOCAL_LAN_OFF.store(off, Ordering::Relaxed);
}

/// The status line while LAN mode is off and nothing managed is happening.
pub fn idle_line() -> String {
    match AGENT.get() {
        Some(a) => format!("{} — LAN connections are turned off. Choose a computer in Connections… (Glide menu or tray).", a.status_line()),
        None => "LAN connections are turned off by your organization's policy.".into(),
    }
}

/// The org line for menus and the Connections window, if managed.
pub fn status_line() -> Option<String> {
    AGENT.get().map(|a| a.status_line())
}

/// A status line that takes over the session thread (a request in progress or a recent note).
pub fn status() -> Option<String> {
    let mut st = STATE.lock().unwrap();
    if let Some(c) = &st.connecting {
        return Some(c.clone());
    }
    match &st.note {
        Some((n, at)) if at.elapsed() < NOTE_SHOWN => Some(n.clone()),
        Some(_) => {
            st.note = None;
            None
        }
        None => None,
    }
}

/// A request is in progress or a session waits to start.
pub fn busy() -> bool {
    let st = STATE.lock().unwrap();
    st.connecting.is_some() || st.pending.is_some()
}

pub fn take_pending() -> Option<ManagedSession> {
    STATE.lock().unwrap().pending.take()
}

pub fn set_note(text: String) {
    STATE.lock().unwrap().note = Some((text, Instant::now()));
}

pub fn set_active(a: Option<Active>) {
    STATE.lock().unwrap().active = a;
}

pub fn active() -> Option<Active> {
    STATE.lock().unwrap().active.clone()
}

/// The managed session ended; `by_user` = this viewer's user ended it.
pub fn ended(session_id: &str, by_user: bool) {
    if let Some(a) = AGENT.get() {
        let (a, sid) = (a.clone(), session_id.to_string());
        std::thread::spawn(move || a.ended(&sid, by_user));
    }
}

/// Records an audit event for the running managed session (no-op otherwise).
pub fn audit(f: impl FnOnce(&AuditQueue, &str)) {
    if let (Some(a), Some(s)) = (AGENT.get(), active()) {
        f(&a.audit, &s.session_id);
    }
}

/// Connect to an organization host (Connections window): the request and relay run in the
/// background; the session thread shows the progress and then runs the session.
pub fn start(host: HostEntry) {
    let Some(agent) = AGENT.get().cloned() else { return };
    {
        let mut st = STATE.lock().unwrap();
        if st.connecting.is_some() {
            return;
        }
        st.note = None;
        st.connecting = Some(format!("Connecting to {}…", host.name));
    }
    // Stop whatever the session thread is doing (a LAN connection, dialing, listening).
    super::app::begin_managed();
    std::thread::spawn(move || {
        let r = agent.connect(&host.id, &host.name, &|line| {
            eprintln!("managed: {line}");
            STATE.lock().unwrap().connecting = Some(line);
        });
        let mut st = STATE.lock().unwrap();
        st.connecting = None;
        match r {
            Ok(s) => st.pending = Some(s),
            Err(e) => {
                eprintln!("managed: {e}");
                st.note = Some((e, Instant::now()));
            }
        }
    });
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn message(owner: HWND, text: &str, icon: MESSAGEBOX_STYLE) {
    unsafe {
        let _ = MessageBoxW(Some(owner), PCWSTR(wide(text).as_ptr()), w!("Glide"), MB_OK | icon);
    }
}

/// Opens a URL from the cloud in the default browser: only an `https` URL on the CloudURL's host
/// and port (docs/ENTERPRISE.md §6.7); nothing else is ever launched.
fn open_url(cloud_url: &str, url: &str) {
    if !crate::cloud::managed::browser_url_allowed(cloud_url, url) {
        eprintln!("managed: not opening {url:?} (not an https URL on {cloud_url})");
        return;
    }
    unsafe {
        ShellExecuteW(None, w!("open"), PCWSTR(wide(url).as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

/// "Sign in to your organization…": device authorization grant (§5.2). Opens the browser, shows
/// the code, polls in the background; the dialog closes by itself once signed in.
pub fn sign_in(owner: HWND) {
    let Some(agent) = AGENT.get().cloned() else { return };
    if !agent.enrolled() {
        message(owner, &agent.status_line(), MB_ICONINFORMATION);
        return;
    }
    let start = match agent.begin_sign_in() {
        Ok(s) => s,
        Err(e) => return message(owner, &format!("Can't start signing in: {e}"), MB_ICONWARNING),
    };
    let cloud_url = agent.cloud_url().to_string();
    open_url(&cloud_url, &start.verification_uri_complete);
    let close = Arc::new(AtomicBool::new(false));
    let stop_poll = Arc::new(AtomicBool::new(false));
    let result: Arc<Mutex<Option<Result<crate::cloud::api::User, SignInError>>>> = Arc::new(Mutex::new(None));
    {
        let (agent, start, close, stop_poll, result) = (agent.clone(), start.clone(), close.clone(), stop_poll.clone(), result.clone());
        std::thread::spawn(move || {
            let r = agent.finish_sign_in(&start, &stop_poll);
            *result.lock().unwrap() = Some(r);
            close.store(true, Ordering::SeqCst);
        });
    }
    let url = start.verification_uri_complete.clone();
    let spec = super::prompt::PromptSpec {
        title: format!("Glide — Sign in to {}", agent.org_name()),
        t: super::prompt::PairText {
            text: "Finish signing in in your browser with your work account. If the page asks, check that it shows this code:".into(),
            code: start.user_code.clone(),
            detail: format!("Page: {}\nGlide never sees your password. This window closes by itself once you're signed in.", start.verification_uri),
        },
        confirm: "Open browser again".into(),
        cancel: "Cancel".into(),
        code_pt: 24,
        on_confirm: Some(Box::new(move || open_url(&cloud_url, &url))),
        live_code: None,
    };
    if let Err(e) = super::prompt::ask(Some(owner), spec, close.clone()) {
        eprintln!("managed: {e}");
    }
    stop_poll.store(true, Ordering::SeqCst);
    let r = result.lock().unwrap().take();
    match r {
        Some(Ok(u)) => message(owner, &format!("Signed in to {} as {}.", agent.org_name(), u.label()), MB_ICONINFORMATION),
        Some(Err(SignInError::Cancelled)) | None => {}
        Some(Err(e)) => message(owner, &e.to_string(), MB_ICONWARNING),
    }
}

/// "Sign out": asks first, then revokes the user token (in the background).
pub fn sign_out(owner: HWND) {
    let Some(agent) = AGENT.get().cloned() else { return };
    let who = agent.signed_in().map(|u| u.label()).unwrap_or_default();
    let text = wide(&format!("Sign out {who} from {}? Organization computers stay listed only while you're signed in.", agent.org_name()));
    let ok = unsafe { MessageBoxW(Some(owner), PCWSTR(text.as_ptr()), w!("Glide"), MB_OKCANCEL | MB_ICONQUESTION | MB_DEFBUTTON2) } == IDOK;
    if ok {
        std::thread::spawn(move || agent.sign_out());
    }
}
