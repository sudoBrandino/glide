//! Windows-only host pipeline: DXGI Desktop Duplication of the primary output (`capture`), GPU
//! scaling + BGRA→NV12 with the D3D11 video processor (`convert`), a Media Foundation H.264/HEVC
//! encoder MFT (`encoder`), SendInput (`inject`), cursor polling (`cursor`), the pairing dialog
//! (`confirm`), the notification-area icon (`tray`) and the per-session loop (`session`).
//!
//! Limits of a normal user process (see windows/README.md, glide-host.exe): the secure desktop (UAC
//! prompts, the lock and sign-in screens) can be neither captured nor injected into. While it is
//! up, capture fails with access errors and SendInput is ignored; the host logs this and keeps
//! retrying, and the stream resumes when the normal desktop returns.

pub mod capture;
pub mod confirm;
pub mod convert;
pub mod cursor;
pub mod encoder;
pub mod inject;
pub mod session;
pub mod tray;

/// Per-monitor DPI awareness (v2), so every coordinate and size is in physical pixels.
pub fn set_dpi_awareness() {
    crate::win::set_dpi_awareness();
}

/// The computer name (ServerHello `host_name`).
pub fn computer_name() -> String {
    std::env::var("COMPUTERNAME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "Windows PC".into())
}

/// Format an HRESULT error for logs.
pub fn hr(e: &windows::core::Error) -> String {
    format!("{:#010x} {}", e.code().0 as u32, e.message())
}
