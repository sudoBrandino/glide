//! Typed client for the Glide Cloud device API (docs/ENTERPRISE.md §6.2), over any `Http`.
//! Credentials: `Authorization: Bearer gd_…` (device token) and, for user calls, also
//! `X-Glide-User: gu_…` (§6.1).

use super::api::*;
use super::managed::Url;
use super::transport::{query_escape, Http, Request, WebSocket, WsConnectError};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::sync::Arc;
use std::time::Duration;

/// Default time for an API call.
pub const TIMEOUT: Duration = Duration::from_secs(20);
/// `POST /v1/sessions` waits up to 60 s for the host's answer (§5.3), plus margin.
pub const SESSION_TIMEOUT: Duration = Duration::from_secs(75);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloudError {
    /// No HTTP response (network, TLS, proxy, timeout).
    Transport(String),
    /// An error answer (`status`, `code` from the envelope; code is empty without one).
    Api { status: u16, code: String, message: String },
    /// A response that isn't what the API specifies.
    Decode(String),
}

impl CloudError {
    pub fn status(&self) -> Option<u16> {
        match self {
            CloudError::Api { status, .. } => Some(*status),
            _ => None,
        }
    }
    pub fn code(&self) -> &str {
        match self {
            CloudError::Api { code, .. } => code,
            _ => "",
        }
    }
    pub fn is_unauthorized(&self) -> bool {
        self.status() == Some(401)
    }

    /// A user-facing sentence.
    pub fn user_message(&self) -> String {
        match self {
            CloudError::Transport(e) => format!("Can't reach your organization's Glide service ({e})"),
            CloudError::Decode(e) => format!("Unexpected answer from Glide Cloud ({e})"),
            CloudError::Api { code, message, status } => {
                let known = match code.as_str() {
                    "host_offline" => Some("That computer isn't connected to Glide Cloud right now"),
                    "denied_by_host" => Some("The person at that computer declined the request"),
                    "host_busy" => Some("That computer is already in a session"),
                    "host_no_answer" => Some("That computer didn't answer in time"),
                    "not_allowed" => Some("Your organization doesn't allow you to connect to that computer"),
                    "device_revoked" => Some("This device was removed from your organization"),
                    _ => None,
                };
                match known {
                    Some(k) => k.to_string(),
                    None if !message.trim().is_empty() => message.trim().to_string(),
                    None => format!("Glide Cloud answered HTTP {status}"),
                }
            }
        }
    }
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CloudError::Transport(e) => write!(f, "transport: {e}"),
            CloudError::Api { status, code, message } => write!(f, "HTTP {status} {code}: {message}"),
            CloudError::Decode(e) => write!(f, "bad response: {e}"),
        }
    }
}

/// Glide Cloud as seen by one device.
#[derive(Clone)]
pub struct CloudClient {
    pub base: String,
    http: Arc<dyn Http>,
    device_token: Option<String>,
    user_token: Option<String>,
}

impl CloudClient {
    /// `base` is the normalized CloudURL (`managed::normalize_cloud_url`).
    pub fn new(base: &str, http: Arc<dyn Http>) -> CloudClient {
        CloudClient { base: base.trim_end_matches('/').to_string(), http, device_token: None, user_token: None }
    }

    pub fn with_device(mut self, token: &str) -> CloudClient {
        self.device_token = Some(token.to_string());
        self
    }

    pub fn with_user(mut self, token: Option<&str>) -> CloudClient {
        self.user_token = token.map(str::to_string);
        self
    }

    pub fn http(&self) -> Arc<dyn Http> {
        self.http.clone()
    }

    fn headers(&self, user: bool) -> Vec<(String, String)> {
        let mut h = Vec::new();
        if let Some(t) = &self.device_token {
            h.push(("Authorization".into(), format!("Bearer {t}")));
        }
        if user {
            if let Some(u) = &self.user_token {
                h.push(("X-Glide-User".into(), u.clone()));
            }
        }
        h
    }

    fn call<B: Serialize, R: DeserializeOwned>(&self, method: &'static str, path: &str, body: Option<&B>, user: bool, timeout: Duration) -> Result<Option<R>, CloudError> {
        let mut headers = self.headers(user);
        headers.push(("Accept".into(), "application/json".into()));
        let body = match (method, body) {
            (_, Some(b)) => Some(serde_json::to_vec(b).map_err(|e| CloudError::Decode(e.to_string()))?),
            ("POST", None) => Some(b"{}".to_vec()),
            _ => None,
        };
        if body.is_some() {
            headers.push(("Content-Type".into(), "application/json; charset=utf-8".into()));
        }
        let req = Request { method, url: format!("{}{path}", self.base), headers, body, timeout };
        let resp = self.http.request(&req).map_err(CloudError::Transport)?;
        if !(200..300).contains(&resp.status) {
            let env: Option<ErrorEnvelope> = serde_json::from_slice(&resp.body).ok();
            let (code, message) = env.map(|e| (e.error.code, e.error.message)).unwrap_or_default();
            return Err(CloudError::Api { status: resp.status, code, message: message.chars().take(300).collect() });
        }
        if resp.status == 204 || resp.body.iter().all(u8::is_ascii_whitespace) {
            return Ok(None);
        }
        serde_json::from_slice(&resp.body).map(Some).map_err(|e| CloudError::Decode(e.to_string()))
    }

    fn need<R>(r: Result<Option<R>, CloudError>) -> Result<R, CloudError> {
        r?.ok_or_else(|| CloudError::Decode("empty response body".into()))
    }

    pub fn enroll(&self, req: &EnrollRequest) -> Result<EnrollResponse, CloudError> {
        let anon = CloudClient { device_token: None, user_token: None, ..self.clone() };
        Self::need(anon.call("POST", "/v1/enroll", Some(req), false, TIMEOUT))
    }

    pub fn device(&self) -> Result<DeviceInfo, CloudError> {
        Self::need(self.call::<(), _>("GET", "/v1/device", None, false, TIMEOUT))
    }

    pub fn heartbeat(&self, req: &HeartbeatRequest) -> Result<(), CloudError> {
        self.call::<_, serde_json::Value>("POST", "/v1/device/heartbeat", Some(req), false, TIMEOUT).map(|_| ())
    }

    pub fn audit(&self, batch: &AuditBatch) -> Result<(), CloudError> {
        self.call::<_, serde_json::Value>("POST", "/v1/audit", Some(batch), false, TIMEOUT).map(|_| ())
    }

    pub fn device_start(&self) -> Result<DeviceStartResponse, CloudError> {
        Self::need(self.call::<(), _>("POST", "/v1/auth/device/start", None, false, TIMEOUT))
    }

    pub fn device_token(&self, device_code: &str) -> Result<DeviceTokenResponse, CloudError> {
        Self::need(self.call("POST", "/v1/auth/device/token", Some(&DeviceTokenRequest { device_code: device_code.into() }), false, TIMEOUT))
    }

    pub fn signout(&self) -> Result<(), CloudError> {
        self.call::<(), serde_json::Value>("POST", "/v1/auth/signout", None, true, TIMEOUT).map(|_| ())
    }

    pub fn me(&self) -> Result<MeResponse, CloudError> {
        Self::need(self.call::<(), _>("GET", "/v1/me", None, true, TIMEOUT))
    }

    pub fn hosts(&self) -> Result<HostsResponse, CloudError> {
        Self::need(self.call::<(), _>("GET", "/v1/hosts", None, true, TIMEOUT))
    }

    pub fn create_session(&self, req: &SessionRequest) -> Result<SessionResponse, CloudError> {
        Self::need(self.call("POST", "/v1/sessions", Some(req), true, SESSION_TIMEOUT))
    }

    /// `user` = the viewer ends it (with its user token); false = the host device ends it.
    pub fn end_session(&self, session_id: &str, user: bool) -> Result<(), CloudError> {
        let path = format!("/v1/sessions/{}/end", query_escape(session_id));
        self.call::<(), serde_json::Value>("POST", &path, None, user, TIMEOUT).map(|_| ())
    }

    /// `GET /v1/hub` as a WebSocket.
    pub fn hub(&self) -> Result<Arc<dyn WebSocket>, WsConnectError> {
        let u = Url::parse(&self.base).map_err(WsConnectError::Transport)?;
        let scheme = if u.secure() { "wss" } else { "ws" };
        let url = format!("{scheme}{}/v1/hub", &u.origin()[u.scheme.len()..]);
        self.http.websocket(&url, &self.headers(false))
    }

    /// Opens the relay for a session: `relay_url` must be this cloud's
    /// `wss://<cloud>/v1/relay/<session_id>` (anything else is refused); the ticket is appended.
    pub fn relay(&self, relay_url: &str, session_id: &str, ticket: &str) -> Result<Arc<dyn WebSocket>, WsConnectError> {
        let url = check_relay_url(&self.base, relay_url, session_id).map_err(WsConnectError::Transport)?;
        self.http.websocket(&format!("{url}?ticket={}", query_escape(ticket)), &[])
    }
}

/// `relay_url` names this cloud's relay for `session_id`: same host and port as `cloud_base`,
/// WSS (WS only when the cloud itself is plain HTTP on loopback), path `/v1/relay/<session_id>`.
/// Returns it without query.
pub fn check_relay_url(cloud_base: &str, relay_url: &str, session_id: &str) -> Result<String, String> {
    let c = Url::parse(cloud_base)?;
    let r = Url::parse(relay_url)?;
    let want_scheme = if c.secure() { "wss" } else { "ws" };
    if r.scheme != want_scheme {
        return Err(format!("relay URL must use {want_scheme}://"));
    }
    if r.host != c.host || r.port != c.port {
        return Err("relay URL is not on the organization's Glide Cloud".into());
    }
    let path = r.path.split('?').next().unwrap_or("");
    if session_id.is_empty() || !session_id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_') || path != format!("/v1/relay/{session_id}") {
        return Err("relay URL doesn't match the session".into());
    }
    Ok(format!("{}{path}", r.origin()))
}

/// Fake HTTP for tests: scripted responses by "METHOD path", recorded requests.
#[cfg(test)]
pub mod fake {
    use super::*;
    use crate::cloud::transport::Response;
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct FakeHttp {
        pub routes: Mutex<HashMap<String, VecDeque<Response>>>,
        pub requests: Mutex<Vec<Request>>,
        pub sockets: Mutex<VecDeque<Result<Arc<dyn WebSocket>, WsConnectError>>>,
        pub ws_urls: Mutex<Vec<(String, Vec<(String, String)>)>>,
    }

    impl FakeHttp {
        pub fn on(&self, key: &str, status: u16, body: &str) {
            self.routes.lock().unwrap().entry(key.into()).or_default().push_back(Response { status, body: body.as_bytes().to_vec() });
        }
        pub fn count(&self, key: &str) -> usize {
            self.requests.lock().unwrap().iter().filter(|r| format!("{} {}", r.method, path_of(&r.url)) == key).count()
        }
    }

    fn path_of(url: &str) -> String {
        Url::parse(url).map(|u| u.path).unwrap_or_default()
    }

    impl Http for FakeHttp {
        fn request(&self, req: &Request) -> Result<Response, String> {
            self.requests.lock().unwrap().push(req.clone());
            let key = format!("{} {}", req.method, path_of(&req.url));
            let mut routes = self.routes.lock().unwrap();
            let q = routes.get_mut(&key).ok_or_else(|| format!("no route for {key}"))?;
            // The last response repeats.
            if q.len() > 1 {
                Ok(q.pop_front().unwrap())
            } else {
                q.front().cloned().ok_or_else(|| format!("no response for {key}"))
            }
        }
        fn websocket(&self, url: &str, headers: &[(String, String)]) -> Result<Arc<dyn WebSocket>, WsConnectError> {
            self.ws_urls.lock().unwrap().push((url.into(), headers.to_vec()));
            self.sockets.lock().unwrap().pop_front().unwrap_or(Err(WsConnectError::Transport("no socket scripted".into())))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeHttp;
    use super::*;

    fn header<'a>(r: &'a Request, name: &str) -> Option<&'a str> {
        r.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }

    #[test]
    fn credentials_and_paths() {
        let http = Arc::new(FakeHttp::default());
        http.on("GET /v1/hosts", 200, r#"{"hosts":[]}"#);
        http.on("POST /v1/device/heartbeat", 204, "");
        http.on("POST /v1/enroll", 201, r#"{"device_id":"dev_1","device_token":"gd_new","org":{"id":"o","slug":"s","name":"N"},"settings":{}}"#);
        let c = CloudClient::new("https://glide.example.com/", http.clone()).with_device("gd_abc").with_user(Some("gu_def"));
        assert!(c.hosts().unwrap().hosts.is_empty());
        c.heartbeat(&HeartbeatRequest { app_version: "1".into(), os_version: "2".into(), name: None }).unwrap();
        let e = c
            .enroll(&EnrollRequest {
                enrollment_token: "t".into(),
                kind: "viewer".into(),
                public_key: "00".repeat(32),
                name: "n".into(),
                platform: "windows".into(),
                os_version: "1".into(),
                app_version: "1".into(),
                tags: None,
            })
            .unwrap();
        assert_eq!(e.device_token, "gd_new");
        let reqs = http.requests.lock().unwrap();
        assert_eq!(reqs[0].url, "https://glide.example.com/v1/hosts");
        assert_eq!(header(&reqs[0], "Authorization"), Some("Bearer gd_abc"));
        assert_eq!(header(&reqs[0], "X-Glide-User"), Some("gu_def"));
        assert_eq!(reqs[0].body, None);
        // Device-only call: no user header.
        assert_eq!(header(&reqs[1], "X-Glide-User"), None);
        assert_eq!(header(&reqs[1], "Content-Type"), Some("application/json; charset=utf-8"));
        // Enrollment carries no bearer at all.
        assert_eq!(header(&reqs[2], "Authorization"), None);
    }

    #[test]
    fn errors() {
        let http = Arc::new(FakeHttp::default());
        http.on("POST /v1/sessions", 409, r#"{ "error": { "code": "host_offline", "message": "The host is not connected." } }"#);
        http.on("GET /v1/me", 401, "");
        http.on("POST /v1/auth/device/start", 200, "not json");
        let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x").with_user(Some("gu_y"));
        let e = c.create_session(&SessionRequest { host_id: "dev_h".into(), view_only: None }).unwrap_err();
        assert_eq!((e.status(), e.code()), (Some(409), "host_offline"));
        assert_eq!(e.user_message(), "That computer isn't connected to Glide Cloud right now");
        assert!(c.me().unwrap_err().is_unauthorized());
        assert!(matches!(c.device_start(), Err(CloudError::Decode(_))));
        assert_eq!(http.requests.lock().unwrap()[0].timeout, SESSION_TIMEOUT);
        // No server at all.
        assert!(matches!(c.device(), Err(CloudError::Transport(_))));
    }

    #[test]
    fn hub_and_relay_urls() {
        let http = Arc::new(FakeHttp::default());
        let c = CloudClient::new("https://glide.example.com", http.clone()).with_device("gd_x");
        let _ = c.hub();
        let _ = c.relay("wss://glide.example.com/v1/relay/ses_ABC", "ses_ABC", "eyJ.sig");
        let urls = http.ws_urls.lock().unwrap();
        assert_eq!(urls[0].0, "wss://glide.example.com/v1/hub");
        assert!(urls[0].1.contains(&("Authorization".into(), "Bearer gd_x".into())));
        assert_eq!(urls[1].0, "wss://glide.example.com/v1/relay/ses_ABC?ticket=eyJ.sig");
        assert!(urls[1].1.is_empty(), "the relay authenticates with the ticket only");
        drop(urls);

        let ok = |r: &str| check_relay_url("https://glide.example.com", r, "ses_1");
        assert_eq!(ok("wss://glide.example.com/v1/relay/ses_1"), Ok("wss://glide.example.com/v1/relay/ses_1".into()));
        assert!(ok("wss://evil.example.com/v1/relay/ses_1").is_err());
        assert!(ok("ws://glide.example.com/v1/relay/ses_1").is_err());
        assert!(ok("wss://glide.example.com:8443/v1/relay/ses_1").is_err());
        assert!(ok("wss://glide.example.com/v1/relay/ses_2").is_err());
        assert!(check_relay_url("https://glide.example.com", "wss://glide.example.com/v1/relay/../x", "../x").is_err());
        assert_eq!(check_relay_url("http://127.0.0.1:8787", "ws://127.0.0.1:8787/v1/relay/ses_1", "ses_1"), Ok("ws://127.0.0.1:8787/v1/relay/ses_1".into()));
        let lo = CloudClient::new("http://127.0.0.1:8787", http.clone());
        let _ = lo.hub();
        assert_eq!(http.ws_urls.lock().unwrap()[2].0, "ws://127.0.0.1:8787/v1/hub");
    }
}
