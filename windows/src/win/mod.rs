//! Windows-only: D3D11 + Media Foundation decode, renderer, window/input, probe.

pub mod app;
pub mod bench_decoder;
pub mod console;
pub mod cursor;
pub mod d3d;
pub mod decoder;
pub mod dpapi;
pub mod placement;
pub mod probe;
pub mod prompt;
pub mod render;
pub mod tray;

use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

pub fn set_dpi_awareness() {
    unsafe {
        let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(
            windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        );
    }
}

/// A monitor's physical size in pixels (Per-Monitor-V2 aware: with NVIDIA DSR this is the DSR
/// desktop size, e.g. 3072x1728), its full rect and work area, and its refresh rate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorInfo {
    pub handle: isize,
    pub w: u16,
    pub h: u16,
    pub fps: u8,
    pub rect: windows::Win32::Foundation::RECT,
    pub work: windows::Win32::Foundation::RECT,
}

pub fn monitor_info(hmon: HMONITOR) -> Option<MonitorInfo> {
    unsafe {
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if !GetMonitorInfoW(hmon, &mut mi as *mut MONITORINFOEXW as *mut MONITORINFO).as_bool() {
            return None;
        }
        let r = mi.monitorInfo.rcMonitor;
        let (w, h) = ((r.right - r.left).max(0), (r.bottom - r.top).max(0));
        if w == 0 || h == 0 {
            return None;
        }
        let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
        let fps = if EnumDisplaySettingsW(windows::core::PCWSTR(mi.szDevice.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
            dm.dmDisplayFrequency.clamp(30, 240) as u8
        } else {
            60
        };
        Some(MonitorInfo {
            handle: hmon.0 as isize,
            w: w.min(65535) as u16,
            h: h.min(65535) as u16,
            fps,
            rect: r,
            work: mi.monitorInfo.rcWork,
        })
    }
}

/// The monitor under the mouse cursor (where the viewer window will open).
pub fn cursor_monitor() -> Option<MonitorInfo> {
    unsafe {
        let mut pt = windows::Win32::Foundation::POINT::default();
        let _ = GetCursorPos(&mut pt);
        monitor_info(MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY))
    }
}

/// (width, height, refresh-capped max_fps) of the monitor the viewer will open on (the one under
/// the cursor), in physical pixels. Falls back to the primary display, then 3840x2160@120 when
/// no display is available (e.g. SSH session 0).
pub fn display_info() -> (u16, u16, u8) {
    set_dpi_awareness();
    if let Some(m) = cursor_monitor() {
        return (m.w, m.h, m.fps);
    }
    unsafe {
        let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
        if EnumDisplaySettingsW(None, ENUM_CURRENT_SETTINGS, &mut dm).as_bool() && dm.dmPelsWidth > 0 {
            let fps = dm.dmDisplayFrequency.clamp(30, 240) as u8;
            (dm.dmPelsWidth.min(65535) as u16, dm.dmPelsHeight.min(65535) as u16, fps)
        } else {
            let w = GetSystemMetrics(SM_CXSCREEN);
            let h = GetSystemMetrics(SM_CYSCREEN);
            if w > 0 && h > 0 { (w as u16, h as u16, 60) } else { (3840, 2160, 120) }
        }
    }
}
