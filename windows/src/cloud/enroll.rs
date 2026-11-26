//! Device enrollment (docs/ENTERPRISE.md §5.1): with no stored enrollment, or one for a different
//! `CloudURL`, call `POST /v1/enroll` with the managed `EnrollmentToken` and store the result.

use super::api::{EnrollRequest, Settings};
use super::client::{CloudClient, CloudError};
use super::managed::ManagedConfig;
use super::store::{Enrollment, Store};
use crate::util::hex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Host,
    Viewer,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Host => "host",
            Kind::Viewer => "viewer",
        }
    }
    pub fn file(self) -> &'static str {
        match self {
            Kind::Host => super::store::HOST_FILE,
            Kind::Viewer => super::store::VIEWER_FILE,
        }
    }
}

/// What this installation tells the cloud about itself.
#[derive(Debug, Clone)]
pub struct DeviceFacts {
    pub kind: Kind,
    pub public_key: [u8; 32],
    /// Managed `DeviceName`, else the computer name.
    pub name: String,
    pub os_version: String,
    pub app_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnrollError {
    /// Not enrolled and no `EnrollmentToken` configured.
    NoToken,
    /// `409 device_revoked`: this device's key was revoked; enrolling it again is refused.
    Revoked,
    /// `401 invalid_enrollment_token`: retrying won't help until the configuration changes.
    Refused(String),
    /// Couldn't reach the cloud, or a server error: retry later.
    Retry(String),
    /// The enrollment file can't be read or written.
    Storage(String),
}

impl std::fmt::Display for EnrollError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnrollError::NoToken => write!(f, "not enrolled and no EnrollmentToken is configured"),
            EnrollError::Revoked => write!(f, "this device was revoked by the organization"),
            EnrollError::Refused(e) => write!(f, "enrollment refused: {e}"),
            EnrollError::Retry(e) => write!(f, "enrollment failed, will retry: {e}"),
            EnrollError::Storage(e) => write!(f, "{e}"),
        }
    }
}

/// The stored enrollment if it is for `managed.cloud_url`; otherwise enrolls (replacing one for
/// another cloud) and stores the result.
pub fn ensure(managed: &ManagedConfig, store: &Store, client: &CloudClient, facts: &DeviceFacts) -> Result<Enrollment, EnrollError> {
    match store.load() {
        // Revoked at this CloudURL: never enroll again until the CloudURL changes (§6.7).
        Ok(Some(e)) if e.cloud_url == managed.cloud_url && e.revoked => return Err(EnrollError::Revoked),
        Ok(Some(e)) if e.cloud_url == managed.cloud_url && e.plausible() => return Ok(e),
        Ok(Some(e)) => {
            crate::host::log(&format!("cloud: stored enrollment is for {} (now {}); enrolling again", e.cloud_url, managed.cloud_url));
            store.wipe().map_err(EnrollError::Storage)?;
        }
        Ok(None) => {}
        Err(e) => return Err(EnrollError::Storage(e)),
    }
    let token = managed.enrollment_token.clone().ok_or(EnrollError::NoToken)?;
    let req = EnrollRequest {
        enrollment_token: token,
        kind: facts.kind.name().into(),
        public_key: hex(&facts.public_key),
        name: facts.name.clone(),
        platform: "windows".into(),
        os_version: facts.os_version.clone(),
        app_version: facts.app_version.clone(),
        tags: (!managed.tags.is_empty()).then(|| managed.tags.clone()),
    };
    let r = client.enroll(&req).map_err(classify).inspect_err(|e| {
        if *e == EnrollError::Revoked {
            // 409 device_revoked: remembered, so a restart doesn't ask again.
            if let Err(err) = store.mark_revoked(&managed.cloud_url, None, "") {
                crate::host::log(&format!("cloud: {err}"));
            }
        }
    })?;
    let e = Enrollment {
        cloud_url: managed.cloud_url.clone(),
        org_id: r.org.id.clone(),
        device_id: r.device_id,
        device_token: r.device_token,
        enrolled_at: crate::config::rfc3339_utc(std::time::SystemTime::now()),
        org_name: r.org.name,
        settings: Some(r.settings),
        ..Default::default()
    };
    if !e.plausible() {
        return Err(EnrollError::Retry("the enrollment answer has no usable device token".into()));
    }
    store.save(&e).map_err(EnrollError::Storage)?;
    Ok(e)
}

fn classify(e: CloudError) -> EnrollError {
    match &e {
        CloudError::Api { status: 409, code, .. } if code == "device_revoked" => EnrollError::Revoked,
        CloudError::Api { status: 401, code, .. } if code == "invalid_enrollment_token" => EnrollError::Refused(e.user_message()),
        _ => EnrollError::Retry(e.to_string()),
    }
}

/// Keep the newest settings in the enrollment file (startup LAN decision); errors are logged.
pub fn remember_settings(store: &Store, settings: &Settings) {
    if let Ok(Some(mut e)) = store.load() {
        if e.settings.as_ref() != Some(settings) {
            e.settings = Some(settings.clone());
            if let Err(err) = store.save(&e) {
                crate::host::log(&format!("cloud: {err}"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::client::fake::FakeHttp;
    use crate::cloud::store::{temp_dir, Plain};
    use std::sync::Arc;

    fn setup(token: Option<&str>) -> (Arc<FakeHttp>, CloudClient, Store, ManagedConfig, DeviceFacts, std::path::PathBuf) {
        let http = Arc::new(FakeHttp::default());
        let client = CloudClient::new("https://c.example.com", http.clone());
        let dir = temp_dir("enroll");
        let store = Store::new(&dir, Kind::Host.file(), Arc::new(Plain));
        let m = ManagedConfig { cloud_url: "https://c.example.com".into(), enrollment_token: token.map(Into::into), tags: vec!["lab".into()], ..Default::default() };
        let f = DeviceFacts { kind: Kind::Host, public_key: [7; 32], name: "PC".into(), os_version: "10.0".into(), app_version: "0.3.1".into() };
        (http, client, store, m, f, dir)
    }

    const OK: &str = r#"{"device_id":"dev_1","device_token":"gd_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","org":{"id":"org_1","slug":"acme","name":"Acme"},"settings":{"lan_mode":false}}"#;

    #[test]
    fn enrolls_once_then_reuses() {
        let (http, client, store, m, f, dir) = setup(Some("enr_x"));
        http.on("POST /v1/enroll", 201, OK);
        let e = ensure(&m, &store, &client, &f).unwrap();
        assert_eq!((e.device_id.as_str(), e.org_name.as_str()), ("dev_1", "Acme"));
        assert!(!e.settings.unwrap().lan_mode);
        let body: serde_json::Value = serde_json::from_slice(http.requests.lock().unwrap()[0].body.as_ref().unwrap()).unwrap();
        assert_eq!(body["kind"], "host");
        assert_eq!(body["public_key"], "07".repeat(32));
        assert_eq!(body["platform"], "windows");
        assert_eq!(body["tags"], serde_json::json!(["lab"]));
        ensure(&m, &store, &client, &f).unwrap();
        assert_eq!(http.count("POST /v1/enroll"), 1, "the stored enrollment is reused");
        // Another CloudURL: enroll again.
        let m2 = ManagedConfig { cloud_url: "https://other.example.com".into(), ..m.clone() };
        let c2 = CloudClient::new("https://other.example.com", http.clone());
        ensure(&m2, &store, &c2, &f).unwrap();
        assert_eq!(http.count("POST /v1/enroll"), 2);
        assert_eq!(store.load().unwrap().unwrap().cloud_url, "https://other.example.com");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn errors() {
        let (http, client, store, m, f, dir) = setup(None);
        assert_eq!(ensure(&m, &store, &client, &f), Err(EnrollError::NoToken));
        let m = ManagedConfig { enrollment_token: Some("t".into()), ..m };
        http.on("POST /v1/enroll", 409, r#"{"error":{"code":"device_revoked","message":"revoked"}}"#);
        assert_eq!(ensure(&m, &store, &client, &f), Err(EnrollError::Revoked));
        // Remembered: the next start doesn't ask the cloud again (same CloudURL).
        assert!(store.revoked_for(&m.cloud_url).is_some());
        assert_eq!(ensure(&m, &store, &client, &f), Err(EnrollError::Revoked));
        assert_eq!(http.count("POST /v1/enroll"), 1);
        // Another CloudURL enrolls afresh.
        let m2 = ManagedConfig { cloud_url: "https://other.example.com".into(), ..m.clone() };
        let c2 = CloudClient::new("https://other.example.com", http.clone());
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/enroll", 201, OK);
        assert!(ensure(&m2, &store, &c2, &f).is_ok());
        store.wipe().unwrap();
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/enroll", 401, r#"{"error":{"code":"invalid_enrollment_token","message":"The enrollment token is not valid."}}"#);
        assert_eq!(ensure(&m, &store, &client, &f), Err(EnrollError::Refused("The enrollment token is not valid.".into())));
        // Anything else retries (with backoff), even other 4xx answers.
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/enroll", 403, r#"{"error":{"code":"forbidden","message":"x"}}"#);
        assert!(matches!(ensure(&m, &store, &client, &f), Err(EnrollError::Retry(_))));
        http.routes.lock().unwrap().clear();
        http.on("POST /v1/enroll", 503, "");
        assert!(matches!(ensure(&m, &store, &client, &f), Err(EnrollError::Retry(_))));
        assert_eq!(store.load(), Ok(None), "nothing stored on failure");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn settings_are_remembered() {
        let (http, client, store, m, f, dir) = setup(Some("t"));
        http.on("POST /v1/enroll", 201, OK);
        ensure(&m, &store, &client, &f).unwrap();
        let s = Settings { lan_mode: true, allow_local_pairing: false, ..Settings::default() };
        remember_settings(&store, &s);
        assert_eq!(store.load().unwrap().unwrap().settings, Some(s));
        let _ = std::fs::remove_dir_all(dir);
    }
}
