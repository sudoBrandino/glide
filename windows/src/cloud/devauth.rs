//! User sign-in on a viewer with the device authorization grant (docs/ENTERPRISE.md §5.2,
//! RFC 8628 shape): `POST /v1/auth/device/start`, show `user_code` and open
//! `verification_uri_complete`, then poll `POST /v1/auth/device/token` every `interval` seconds
//! (5 s more after each `slow_down`) until approved, denied or expired.

use super::api::{DeviceStartResponse, DeviceTokenResponse};
use super::client::{CloudClient, CloudError};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignInError {
    Cancelled,
    /// The user chose Deny on the Glide Cloud page.
    Denied,
    /// The code expired before it was approved.
    Expired,
    Failed(String),
}

impl std::fmt::Display for SignInError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SignInError::Cancelled => write!(f, "Sign-in cancelled"),
            SignInError::Denied => write!(f, "Sign-in was denied in the browser"),
            SignInError::Expired => write!(f, "The sign-in code expired; try again"),
            SignInError::Failed(e) => write!(f, "Sign-in failed: {e}"),
        }
    }
}

/// One poll's outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Poll {
    Done(DeviceTokenResponse),
    Pending,
    SlowDown,
    Denied,
    Expired,
    /// Network trouble or a server error: keep polling until the code expires.
    Transient(String),
    Failed(String),
}

pub fn classify(r: Result<DeviceTokenResponse, CloudError>) -> Poll {
    match r {
        Ok(t) if t.user_token.starts_with("gu_") => Poll::Done(t),
        Ok(_) => Poll::Failed("the sign-in answer has no usable user token".into()),
        Err(e) => match (e.status(), e.code()) {
            (Some(400), "authorization_pending") => Poll::Pending,
            (Some(400), "slow_down") => Poll::SlowDown,
            (Some(400), "expired_token") => Poll::Expired,
            (Some(400), "access_denied") => Poll::Denied,
            (Some(s), _) if s >= 500 || s == 429 => Poll::Transient(e.to_string()),
            (None, _) => Poll::Transient(e.to_string()),
            _ => Poll::Failed(e.user_message()),
        },
    }
}

/// Longest wait between polls after repeated network or server errors.
pub const TRANSIENT_MAX: Duration = Duration::from_secs(60);

/// Polls until done (§6.7): every `interval` (5 s more after each `slow_down`); network errors,
/// `429` and `5xx` are retried with a delay that doubles from `interval` up to `TRANSIENT_MAX`,
/// until `expires_in`; any other error stops. `sleep(d)` waits and returns false when cancelled.
pub fn poll(client: &CloudClient, start: &DeviceStartResponse, cancel: &AtomicBool, sleep: &dyn Fn(Duration) -> bool) -> Result<DeviceTokenResponse, SignInError> {
    let deadline = Instant::now() + Duration::from_secs(start.expires_in.clamp(30, 1800));
    let mut interval = Duration::from_secs(start.interval.clamp(1, 60));
    let mut delay = interval;
    loop {
        if cancel.load(Ordering::SeqCst) || !sleep(delay) {
            return Err(SignInError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(SignInError::Expired);
        }
        match classify(client.device_token(&start.device_code)) {
            Poll::Done(t) => return Ok(t),
            Poll::Pending => delay = interval,
            Poll::Transient(e) => {
                crate::host::log(&format!("cloud: sign-in poll failed ({e}); retrying"));
                delay = (delay * 2).min(TRANSIENT_MAX.max(interval));
            }
            Poll::SlowDown => {
                interval += Duration::from_secs(5);
                delay = interval;
            }
            Poll::Denied => return Err(SignInError::Denied),
            Poll::Expired => return Err(SignInError::Expired),
            Poll::Failed(e) => return Err(SignInError::Failed(e)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::client::fake::FakeHttp;
    use std::sync::{Arc, Mutex};

    fn start() -> DeviceStartResponse {
        DeviceStartResponse {
            device_code: "dc".into(),
            user_code: "ABCD-EFGH".into(),
            verification_uri: "https://c/auth/device".into(),
            verification_uri_complete: Some("https://c/auth/device?user_code=ABCD-EFGH".into()),
            interval: 5,
            expires_in: 600,
        }
    }

    fn err(code: &str) -> String {
        format!(r#"{{"error":{{"code":"{code}","message":"x"}}}}"#)
    }

    #[test]
    fn pending_slow_down_then_token() {
        let http = Arc::new(FakeHttp::default());
        http.on("POST /v1/auth/device/token", 400, &err("authorization_pending"));
        http.on("POST /v1/auth/device/token", 503, "");
        http.on("POST /v1/auth/device/token", 400, &err("slow_down"));
        http.on("POST /v1/auth/device/token", 200, r#"{"user_token":"gu_tok","expires_in":43200,"user":{"id":"usr_1","email":"a@example.com","name":"A"}}"#);
        let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        let slept = Mutex::new(Vec::new());
        let t = poll(&c, &start(), &AtomicBool::new(false), &|d| {
            slept.lock().unwrap().push(d.as_secs());
            true
        })
        .unwrap();
        assert_eq!(t.user_token, "gu_tok");
        assert_eq!(*slept.lock().unwrap(), vec![5, 5, 10, 10], "a 503 backs off; slow_down adds 5 s");
        let body: serde_json::Value = serde_json::from_slice(http.requests.lock().unwrap()[0].body.as_ref().unwrap()).unwrap();
        assert_eq!(body, serde_json::json!({"device_code":"dc"}));
    }

    #[test]
    fn transient_errors_back_off_and_retry() {
        let http = Arc::new(FakeHttp::default());
        for status in [503, 500, 429, 502, 504, 503] {
            http.on("POST /v1/auth/device/token", status, "");
        }
        http.on("POST /v1/auth/device/token", 400, &err("authorization_pending"));
        http.on("POST /v1/auth/device/token", 200, r#"{"user_token":"gu_tok","expires_in":43200}"#);
        let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        let slept = Mutex::new(Vec::new());
        let t = poll(&c, &start(), &AtomicBool::new(false), &|d| {
            slept.lock().unwrap().push(d.as_secs());
            true
        })
        .unwrap();
        assert_eq!(t.user_token, "gu_tok");
        // At least `interval` apart, doubling to 60 s, back to `interval` once the cloud answers.
        assert_eq!(*slept.lock().unwrap(), vec![5, 10, 20, 40, 60, 60, 60, 5]);
        // Network errors (no route here) are transient too.
        assert!(matches!(classify(Err(CloudError::Transport("down".into()))), Poll::Transient(_)));
        // Other errors stop at once.
        for (status, body) in [(401, String::new()), (403, err("forbidden")), (400, err("invalid_request")), (404, String::new())] {
            let http = Arc::new(FakeHttp::default());
            http.on("POST /v1/auth/device/token", status, &body);
            let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
            assert!(matches!(poll(&c, &start(), &AtomicBool::new(false), &|_| true), Err(SignInError::Failed(_))), "{status}");
            assert_eq!(http.count("POST /v1/auth/device/token"), 1);
        }
    }

    #[test]
    fn denied_expired_cancelled() {
        let run = |code: &str| {
            let http = Arc::new(FakeHttp::default());
            http.on("POST /v1/auth/device/token", 400, &err(code));
            let c = CloudClient::new("https://c.example.com", http).with_device("gd_x");
            poll(&c, &start(), &AtomicBool::new(false), &|_| true)
        };
        assert_eq!(run("access_denied"), Err(SignInError::Denied));
        assert_eq!(run("expired_token"), Err(SignInError::Expired));
        assert!(matches!(run("invalid_grant"), Err(SignInError::Failed(_))));
        let http = Arc::new(FakeHttp::default());
        let c = CloudClient::new("https://c.example.com", http).with_device("gd_x");
        assert_eq!(poll(&c, &start(), &AtomicBool::new(true), &|_| true), Err(SignInError::Cancelled));
        assert_eq!(poll(&c, &start(), &AtomicBool::new(false), &|_| false), Err(SignInError::Cancelled));
        assert!(matches!(classify(Ok(DeviceTokenResponse { user_token: "nope".into(), expires_in: 1, user: Default::default() })), Poll::Failed(_)));
    }
}
