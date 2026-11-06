//! Monitor enumeration for per-monitor window state (the pure restore logic is in
//! `config::{choose_placement, record_placement}`).

use crate::config::{MonitorDesc, Rect};
use windows::core::BOOL;
use windows::Win32::Foundation::{LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

pub fn rect(r: RECT) -> Rect {
    Rect { l: r.left, t: r.top, r: r.right, b: r.bottom }
}

pub fn win_rect(r: Rect) -> RECT {
    RECT { left: r.l, top: r.t, right: r.r, bottom: r.b }
}

/// Key (device name, e.g. `\\.\DISPLAY1`), full rect and work area of a monitor.
pub fn monitor_desc(hmon: HMONITOR) -> Option<MonitorDesc> {
    unsafe {
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if !GetMonitorInfoW(hmon, &mut mi as *mut MONITORINFOEXW as *mut MONITORINFO).as_bool() {
            return None;
        }
        let n = mi.szDevice.iter().position(|&c| c == 0).unwrap_or(mi.szDevice.len());
        Some(MonitorDesc {
            key: String::from_utf16_lossy(&mi.szDevice[..n]),
            rect: rect(mi.monitorInfo.rcMonitor),
            work: rect(mi.monitorInfo.rcWork),
        })
    }
}

unsafe extern "system" fn enum_cb(hmon: HMONITOR, _dc: HDC, _r: *mut RECT, lp: LPARAM) -> BOOL {
    let v = &mut *(lp.0 as *mut Vec<MonitorDesc>);
    if let Some(d) = monitor_desc(hmon) {
        v.push(d);
    }
    true.into()
}

pub fn monitors() -> Vec<MonitorDesc> {
    let mut v: Vec<MonitorDesc> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(enum_cb), LPARAM(&mut v as *mut _ as isize));
    }
    v
}

/// Index (into `monitors()`) of the monitor under the mouse cursor.
pub fn cursor_monitor_index(ms: &[MonitorDesc]) -> Option<usize> {
    unsafe {
        let mut pt = POINT::default();
        GetCursorPos(&mut pt).ok()?;
        let d = monitor_desc(MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY))?;
        ms.iter().position(|m| m.key == d.key)
    }
}
