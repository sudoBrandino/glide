//! Managed mode (Glide Cloud, docs/ENTERPRISE.md): enrollment, the device API, the hub, the relay
//! bridge, session grants and permissions, client audit events, org settings. Shared by the
//! Windows viewer (`glide-client.exe`) and host (`glide-host.exe`).
//!
//! Everything here is platform independent and unit-tested on any OS, except the WinHTTP
//! transport (`winhttp`, Windows only) and the registry policy source (`managed::registry`).
//!
//! - `managed`: the managed configuration (`HKLM`/`HKCU\SOFTWARE\Policies\Glide`, §11.2).
//! - `api`: JSON wire formats (§6–§9).
//! - `transport`: the HTTP / WebSocket traits; `winhttp`: their WinHTTP implementation.
//! - `client`: the typed device API client.
//! - `store`, `enroll`: the enrollment file (DPAPI, §11.3) and flow (§5.1).
//! - `hub`: the hub WebSocket with reconnect backoff (§6.4); `backoff`.
//! - `bridge`: relay WebSocket ⇄ loopback TCP (§6.6).
//! - `grants`: the host's in-memory, single-use session grants (§6.3).
//! - `perms`: permission enforcement on Glide records (§6.3).
//! - `settings`: what org settings mean here (§7).
//! - `audit`: batched client audit events (§9).
//! - `devauth`: user sign-in with the device authorization grant (§5.2).
//! - `host`, `viewer`: the managed-mode agents the two apps run.

pub mod api;
pub mod audit;
pub mod backoff;
pub mod bridge;
pub mod client;
pub mod devauth;
pub mod enroll;
pub mod grants;
pub mod host;
pub mod hub;
pub mod managed;
pub mod perms;
pub mod settings;
pub mod store;
pub mod transport;
pub mod viewer;
#[cfg(windows)]
pub mod winhttp;

pub use api::{Direction, Permissions, Settings};

/// Pin-store target of a managed session (`relay:<session_id>`, §6.3). Never saved.
pub fn relay_target(session_id: &str) -> String {
    format!("relay:{session_id}")
}

/// The platform HTTP transport (WinHTTP on Windows; none elsewhere).
pub fn platform_http() -> Option<std::sync::Arc<dyn transport::Http>> {
    #[cfg(windows)]
    {
        Some(std::sync::Arc::new(winhttp::WinHttp::new()))
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// "10.0.26100" on Windows (from the registry), else the OS family.
pub fn os_version() -> String {
    #[cfg(windows)]
    {
        winhttp::os_version()
    }
    #[cfg(not(windows))]
    {
        std::env::consts::OS.to_string()
    }
}
