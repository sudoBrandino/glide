//! Hub client (docs/ENTERPRISE.md §6.4): one WebSocket to `GET /v1/hub` per enrolled device,
//! reconnecting with backoff (1 s → 60 s, ±20 %). Pings are answered here; every other frame goes
//! to a `HubHandler`. A `revoked` frame or a 401 on the upgrade ends the loop with
//! `HubExit::Revoked`: the caller deletes the enrollment and ends sessions.

use super::api::{DeviceFrame, ServerFrame};
use super::backoff::Backoff;
use super::client::CloudClient;
use super::transport::{WebSocket, WsConnectError, WsMsg};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A connection that stayed up this long resets the backoff even without `hello`.
const STABLE: Duration = Duration::from_secs(30);

pub trait HubHandler: Send + Sync {
    /// Any frame except `ping` (answered by the hub loop) and `revoked` (ends the loop).
    fn frame(&self, f: ServerFrame, link: &HubLink);
    fn connected(&self) {}
    fn disconnected(&self, _why: &str) {}
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HubExit {
    /// `stop` was set.
    Stopped,
    /// `revoked` frame (its reason), or 401 on the upgrade ("unauthorized").
    Revoked(String),
}

/// The current hub socket, for sending answers from other threads.
#[derive(Default)]
pub struct HubLink {
    ws: Mutex<Option<Arc<dyn WebSocket>>>,
}

impl HubLink {
    pub fn send(&self, f: &DeviceFrame) -> std::io::Result<()> {
        let ws = self.ws.lock().unwrap().clone().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotConnected, "hub not connected"))?;
        let text = serde_json::to_string(f).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        ws.send(WsMsg::Text(text))
    }

    pub fn is_connected(&self) -> bool {
        self.ws.lock().unwrap().is_some()
    }

    /// Close the current socket (the loop reconnects unless stopped).
    pub fn close(&self) {
        if let Some(ws) = self.ws.lock().unwrap().take() {
            ws.close(1000, "");
        }
    }

    pub(crate) fn set(&self, ws: Option<Arc<dyn WebSocket>>) {
        *self.ws.lock().unwrap() = ws;
    }
}

/// Runs the hub until stopped or revoked. `sleep(d)` waits `d` and returns false if the loop
/// should stop instead (tests pass a recording no-op).
pub fn run(client: &CloudClient, handler: &dyn HubHandler, link: &HubLink, stop: &AtomicBool, sleep: &dyn Fn(Duration) -> bool) -> HubExit {
    let mut backoff = Backoff::default();
    loop {
        if stop.load(Ordering::SeqCst) {
            return HubExit::Stopped;
        }
        let ws = match client.hub() {
            Ok(ws) => ws,
            Err(WsConnectError::Status(401)) => return HubExit::Revoked("unauthorized".into()),
            Err(e) => {
                handler.disconnected(&e.to_string());
                if !sleep(backoff.next_delay()) {
                    return HubExit::Stopped;
                }
                continue;
            }
        };
        link.set(Some(ws.clone()));
        if stop.load(Ordering::SeqCst) {
            ws.close(1000, "");
            link.set(None);
            return HubExit::Stopped;
        }
        handler.connected();
        let since = Instant::now();
        let why = loop {
            match ws.recv() {
                Ok(WsMsg::Text(t)) => match serde_json::from_str::<ServerFrame>(&t) {
                    Ok(ServerFrame::Ping { t }) => {
                        let _ = link.send(&DeviceFrame::Pong { t });
                    }
                    Ok(ServerFrame::Revoked { reason }) => {
                        ws.close(1000, "");
                        link.set(None);
                        return HubExit::Revoked(if reason.is_empty() { "revoked".into() } else { reason });
                    }
                    Ok(f) => {
                        if matches!(f, ServerFrame::Hello { .. }) {
                            backoff.reset();
                        }
                        handler.frame(f, link);
                    }
                    Err(e) => match super::api::undecodable_offer_session_id(&t) {
                        // An offer that doesn't decode is still answered: declined (§6.7).
                        Some(session_id) => {
                            crate::host::log(&format!("cloud hub: declining offer {session_id}: it doesn't decode ({e})"));
                            let _ = link.send(&DeviceFrame::SessionAnswer { session_id, accept: false, reason: Some(super::api::decline::POLICY.into()) });
                        }
                        None => crate::host::log(&format!("cloud hub: ignoring a frame that doesn't parse ({e})")),
                    },
                },
                Ok(WsMsg::Binary(_)) => {}
                Ok(WsMsg::Close(code, reason)) => break format!("closed ({code} {reason})"),
                Err(e) => break e.to_string(),
            }
        };
        link.set(None);
        ws.close(1000, "");
        handler.disconnected(&why);
        if since.elapsed() >= STABLE {
            backoff.reset();
        }
        if stop.load(Ordering::SeqCst) || !sleep(backoff.next_delay()) {
            return HubExit::Stopped;
        }
    }
}

/// Stoppable sleep helper for `run`: waits in small steps, false once `stop` is set.
pub fn sleeper(stop: Arc<AtomicBool>) -> impl Fn(Duration) -> bool {
    move |d| {
        let end = Instant::now() + d;
        while Instant::now() < end {
            if stop.load(Ordering::SeqCst) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(100).min(end.saturating_duration_since(Instant::now())));
        }
        !stop.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::client::fake::FakeHttp;
    use crate::cloud::transport::fake::pair;
    use serde_json::json;

    #[derive(Default)]
    struct Rec {
        frames: Mutex<Vec<ServerFrame>>,
        events: Mutex<Vec<String>>,
    }
    impl HubHandler for Rec {
        fn frame(&self, f: ServerFrame, link: &HubLink) {
            if let ServerFrame::SessionOffer(o) = &f {
                link.send(&DeviceFrame::SessionAnswer { session_id: o.session_id.clone(), accept: false, reason: Some("busy".into()) }).unwrap();
            }
            self.frames.lock().unwrap().push(f);
        }
        fn connected(&self) {
            self.events.lock().unwrap().push("connected".into());
        }
        fn disconnected(&self, why: &str) {
            self.events.lock().unwrap().push(format!("disconnected: {why}"));
        }
    }

    fn texts(ws: &crate::cloud::transport::fake::FakeWs) -> Vec<serde_json::Value> {
        ws.sent.lock().unwrap().iter().filter_map(|m| if let WsMsg::Text(t) = m { serde_json::from_str(t).ok() } else { None }).collect()
    }

    #[test]
    fn frames_ping_reconnect_and_revoke() {
        let http = Arc::new(FakeHttp::default());
        let (client_end1, server1) = pair();
        let (client_end2, server2) = pair();
        http.sockets.lock().unwrap().push_back(Err(WsConnectError::Transport("offline".into())));
        http.sockets.lock().unwrap().push_back(Ok(client_end1.clone()));
        http.sockets.lock().unwrap().push_back(Ok(client_end2.clone()));
        let s = |ws: &Arc<crate::cloud::transport::fake::FakeWs>, v: serde_json::Value| ws.send(WsMsg::Text(v.to_string())).unwrap();
        s(&server1, json!({"type":"hello","device_id":"dev_1","settings":{"lan_mode":false},"server_time":"x"}));
        s(&server1, json!({"type":"ping","t":42}));
        s(&server1, json!({"type":"brand_new"}));
        s(&server1, json!({"type":"session_offer","session_id":"ses_1","viewer":{"device_id":"v","name":"PC","public_key":"00"},"user":{"id":"u","email":"a@b","name":"A"},"permissions":{},"approval":"none","relay_url":"wss://c/v1/relay/ses_1","ticket":"t","expires_at":""}));
        s(&server1, json!({"type":"session_offer","session_id":"ses_bad","ticket":7}));
        server1.close(1001, "going away");
        s(&server2, json!({"type":"settings","settings":{"allow_local_pairing":false}}));
        s(&server2, json!({"type":"revoked","reason":"device revoked by admin"}));

        let rec = Rec::default();
        let link = HubLink::default();
        let delays = Mutex::new(Vec::new());
        let client = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        let exit = run(&client, &rec, &link, &AtomicBool::new(false), &|d| {
            delays.lock().unwrap().push(d);
            true
        });
        assert_eq!(exit, HubExit::Revoked("device revoked by admin".into()));
        let frames = rec.frames.lock().unwrap();
        assert!(matches!(frames[0], ServerFrame::Hello { .. }));
        assert_eq!(frames[1], ServerFrame::Unknown);
        assert!(matches!(frames[2], ServerFrame::SessionOffer(_)));
        assert!(matches!(frames[3], ServerFrame::Settings { .. }));
        assert_eq!(frames.len(), 4, "ping and revoked are handled by the loop");
        let sent = texts(&client_end1);
        assert_eq!(sent[0], json!({"type":"pong","t":42}));
        assert_eq!(sent[1], json!({"type":"session_answer","session_id":"ses_1","accept":false,"reason":"busy"}));
        // An offer that doesn't decode never reaches the handler but is declined.
        assert_eq!(sent[2], json!({"type":"session_answer","session_id":"ses_bad","accept":false,"reason":"policy"}));
        // Backoff: 1 s after the failed attempt; reset by hello so 1 s again after the drop.
        let d = delays.lock().unwrap();
        assert_eq!(d.len(), 2);
        assert!(d.iter().all(|d| *d >= Duration::from_millis(800) && *d <= Duration::from_millis(1200)), "{d:?}");
        assert!(!link.is_connected());
        let ev = rec.events.lock().unwrap();
        assert!(ev[0].starts_with("disconnected: offline"));
        assert_eq!(ev[1], "connected");
        // Bearer on the upgrade.
        assert!(http.ws_urls.lock().unwrap()[1].1.contains(&("Authorization".into(), "Bearer gd_x".into())));
    }

    #[test]
    fn unauthorized_upgrade_means_revoked_and_backoff_grows() {
        let http = Arc::new(FakeHttp::default());
        for _ in 0..3 {
            http.sockets.lock().unwrap().push_back(Err(WsConnectError::Status(503)));
        }
        http.sockets.lock().unwrap().push_back(Err(WsConnectError::Status(401)));
        let delays = Mutex::new(Vec::new());
        let client = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        let exit = run(&client, &Rec::default(), &HubLink::default(), &AtomicBool::new(false), &|d| {
            delays.lock().unwrap().push(d);
            true
        });
        assert_eq!(exit, HubExit::Revoked("unauthorized".into()));
        let secs: Vec<f64> = delays.lock().unwrap().iter().map(|d| d.as_secs_f64()).collect();
        assert_eq!(secs.len(), 3);
        for (s, base) in secs.iter().zip([1.0, 2.0, 4.0]) {
            assert!(*s >= base * 0.8 && *s <= base * 1.2, "{secs:?}");
        }
    }

    #[test]
    fn stop() {
        let http = Arc::new(FakeHttp::default());
        let client = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        assert_eq!(run(&client, &Rec::default(), &HubLink::default(), &AtomicBool::new(true), &|_| true), HubExit::Stopped);
        // A sleep that reports "stop" ends the loop after a failed attempt.
        assert_eq!(run(&client, &Rec::default(), &HubLink::default(), &AtomicBool::new(false), &|_| false), HubExit::Stopped);
        assert!(!HubLink::default().is_connected());
        assert!(HubLink::default().send(&DeviceFrame::Pong { t: json!(1) }).is_err());
    }
}
