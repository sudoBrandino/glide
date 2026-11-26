//! Client audit events (docs/ENTERPRISE.md §9), batched to `POST /v1/audit` (≤ 100 events and
//! ≤ 256 KiB per batch, §12): files sent / received (counts, bytes, names unless the org turned
//! `audit_file_names` off), clipboard transfers (direction, kind, size, never contents), a session
//! ended by the local user, and client errors.

use super::api::{audit_type, AuditBatch, AuditEvent};
use super::client::{CloudClient, CloudError};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

pub const BATCH_EVENTS: usize = 100;
pub const BATCH_BYTES: usize = 256 << 10;
/// Events kept while the cloud is unreachable (oldest dropped first).
pub const QUEUE_MAX: usize = 1000;
/// File names reported per event.
const MAX_NAMES: usize = 50;

pub struct AuditQueue {
    q: Mutex<VecDeque<AuditEvent>>,
    /// The org's `audit_file_names`.
    file_names: AtomicBool,
}

impl Default for AuditQueue {
    fn default() -> Self {
        AuditQueue { q: Mutex::new(VecDeque::new()), file_names: AtomicBool::new(true) }
    }
}

fn now() -> String {
    crate::config::rfc3339_utc(std::time::SystemTime::now())
}

fn event(kind: &str, session_id: Option<&str>, detail: serde_json::Value) -> AuditEvent {
    AuditEvent { kind: kind.into(), ts: now(), session_id: session_id.map(str::to_string), detail }
}

impl AuditQueue {
    pub fn set_file_names(&self, on: bool) {
        self.file_names.store(on, Ordering::SeqCst);
    }

    pub fn push(&self, e: AuditEvent) {
        let mut q = self.q.lock().unwrap();
        if q.len() >= QUEUE_MAX {
            q.pop_front();
        }
        q.push_back(e);
    }

    pub fn len(&self) -> usize {
        self.q.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// `session.file_sent` (sent) or `session.file_received`.
    pub fn files(&self, session_id: &str, sent: bool, count: u32, bytes: u64, names: &[String]) {
        let mut d = json!({ "count": count, "bytes": bytes });
        if self.file_names.load(Ordering::SeqCst) && !names.is_empty() {
            d["names"] = json!(names.iter().take(MAX_NAMES).map(|n| n.chars().take(255).collect::<String>()).collect::<Vec<_>>());
        }
        self.push(event(if sent { audit_type::FILE_SENT } else { audit_type::FILE_RECEIVED }, Some(session_id), d));
    }

    /// `session.clipboard`: `to_host` = viewer → host; `image` = PNG, else text. Never contents.
    pub fn clipboard(&self, session_id: &str, to_host: bool, image: bool, bytes: usize) {
        let d = json!({ "direction": if to_host { "to_host" } else { "to_viewer" }, "kind": if image { "image" } else { "text" }, "bytes": bytes });
        self.push(event(audit_type::CLIPBOARD, Some(session_id), d));
    }

    /// `session.local_end`: `host_user` = ended at the host, else at the viewer.
    pub fn local_end(&self, session_id: &str, host_user: bool) {
        self.push(event(audit_type::LOCAL_END, Some(session_id), json!({ "by": if host_user { "host_user" } else { "viewer_user" } })));
    }

    pub fn client_error(&self, session_id: Option<&str>, code: &str, message: &str) {
        self.push(event(audit_type::CLIENT_ERROR, session_id, json!({ "code": code, "message": message.chars().take(500).collect::<String>() })));
    }

    /// Takes the next batch (≤ `BATCH_EVENTS`, ≤ `BATCH_BYTES` serialized).
    pub fn take_batch(&self) -> Vec<AuditEvent> {
        let mut q = self.q.lock().unwrap();
        let mut out = Vec::new();
        let mut size = 16; // {"events":[]}
        while let Some(e) = q.front() {
            let n = serde_json::to_vec(e).map(|v| v.len() + 1).unwrap_or(usize::MAX);
            if n > BATCH_BYTES {
                q.pop_front(); // can't ever be sent
                continue;
            }
            if out.len() >= BATCH_EVENTS || size + n > BATCH_BYTES {
                break;
            }
            size += n;
            out.push(q.pop_front().unwrap());
        }
        out
    }

    /// Puts a batch that couldn't be sent back in front.
    fn requeue(&self, batch: Vec<AuditEvent>) {
        let mut q = self.q.lock().unwrap();
        for e in batch.into_iter().rev() {
            if q.len() >= QUEUE_MAX {
                break;
            }
            q.push_front(e);
        }
    }

    /// Sends everything queued. On a transport or server error the batch goes back (sent later);
    /// a 4xx (other than 401/429) drops it, since resending the same batch would fail again.
    pub fn flush(&self, client: &CloudClient) -> Result<usize, CloudError> {
        let mut sent = 0;
        loop {
            let batch = self.take_batch();
            if batch.is_empty() {
                return Ok(sent);
            }
            let n = batch.len();
            match client.audit(&AuditBatch { events: batch.clone() }) {
                Ok(()) => sent += n,
                Err(e @ CloudError::Api { status, .. }) if (400..500).contains(&status) && status != 401 && status != 429 => {
                    crate::host::log(&format!("cloud audit: dropped {n} events the cloud refused: {e}"));
                }
                Err(e) => {
                    self.requeue(batch);
                    return Err(e);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::client::fake::FakeHttp;
    use std::sync::Arc;

    #[test]
    fn event_shapes() {
        let q = AuditQueue::default();
        q.files("ses_1", true, 2, 300, &["a.txt".into(), "b.txt".into()]);
        q.set_file_names(false);
        q.files("ses_1", false, 1, 5, &["secret.pdf".into()]);
        q.clipboard("ses_1", true, false, 12);
        q.local_end("ses_1", false);
        q.client_error(None, "relay", "boom");
        let b = q.take_batch();
        let v = serde_json::to_value(&b).unwrap();
        assert_eq!(v[0]["type"], "session.file_sent");
        assert_eq!(v[0]["detail"], json!({"count":2,"bytes":300,"names":["a.txt","b.txt"]}));
        assert_eq!(v[1]["type"], "session.file_received");
        assert_eq!(v[1]["detail"], json!({"count":1,"bytes":5}), "audit_file_names off: no names");
        assert_eq!(v[2]["detail"], json!({"direction":"to_host","kind":"text","bytes":12}));
        assert_eq!(v[3]["detail"], json!({"by":"viewer_user"}));
        assert_eq!(v[4]["type"], "client.error");
        assert!(v[4].get("session_id").is_none());
        assert_eq!(v[0]["session_id"], "ses_1");
        assert!(crate::connections::parse_rfc3339(v[0]["ts"].as_str().unwrap()).is_some());
    }

    #[test]
    fn batching_limits() {
        let q = AuditQueue::default();
        for _ in 0..250 {
            q.local_end("ses_1", true);
        }
        assert_eq!(q.take_batch().len(), BATCH_EVENTS);
        assert_eq!(q.take_batch().len(), BATCH_EVENTS);
        assert_eq!(q.take_batch().len(), 50);
        assert!(q.take_batch().is_empty());
        // Big events: the byte limit cuts the batch.
        let big = "x".repeat(400);
        for _ in 0..100 {
            q.client_error(None, &big, &big);
        }
        let b = q.take_batch();
        assert!(serde_json::to_vec(&AuditBatch { events: b.clone() }).unwrap().len() <= BATCH_BYTES);
        // Bounded while offline.
        let q = AuditQueue::default();
        for _ in 0..QUEUE_MAX + 10 {
            q.local_end("s", true);
        }
        assert_eq!(q.len(), QUEUE_MAX);
    }

    #[test]
    fn flush_requeues_on_failure() {
        let http = Arc::new(FakeHttp::default());
        let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
        let q = AuditQueue::default();
        for _ in 0..150 {
            q.local_end("s", true);
        }
        http.on("POST /v1/audit", 503, "");
        assert!(q.flush(&c).is_err());
        assert_eq!(q.len(), 150, "kept for later");
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/audit", 202, "");
        assert_eq!(q.flush(&c), Ok(150));
        assert!(q.is_empty());
        assert_eq!(http.count("POST /v1/audit"), 3);
        let body: serde_json::Value = serde_json::from_slice(http.requests.lock().unwrap()[1].body.as_ref().unwrap()).unwrap();
        assert_eq!(body["events"].as_array().unwrap().len(), 100);
    }

    #[test]
    fn flush_drops_batches_refused_with_4xx_but_keeps_401_and_429() {
        // 400 / 403 / 404 / 413 / 422: dropped (resending the same batch would fail again).
        for status in [400, 403, 404, 413, 422] {
            let http = Arc::new(FakeHttp::default());
            let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
            let q = AuditQueue::default();
            for _ in 0..150 {
                q.local_end("s", true);
            }
            http.on("POST /v1/audit", status, r#"{"error":{"code":"invalid_request","message":"x"}}"#);
            assert_eq!(q.flush(&c), Ok(0), "{status}");
            assert!(q.is_empty(), "{status}: dropped, not retried");
            assert_eq!(http.count("POST /v1/audit"), 2, "both batches tried once");
        }
        // 401, 429, 5xx and no answer: kept for later.
        for status in [401, 429, 500, 503] {
            let http = Arc::new(FakeHttp::default());
            let c = CloudClient::new("https://c.example.com", http.clone()).with_device("gd_x");
            let q = AuditQueue::default();
            q.client_error(Some("ses_1"), "handshake", "x");
            http.on("POST /v1/audit", status, "");
            assert!(q.flush(&c).is_err(), "{status}");
            assert_eq!(q.len(), 1, "{status}: kept");
        }
        let q = AuditQueue::default();
        q.client_error(None, "relay", "x");
        assert!(q.flush(&CloudClient::new("https://c.example.com", Arc::new(FakeHttp::default()))).is_err());
        assert_eq!(q.len(), 1);
    }
}
