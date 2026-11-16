//! Cursor: GetCursorInfo polling at ~120 Hz → CursorPos (normalized over the captured output,
//! visible only while showing and on that output); shape changes → CursorShape (BGRA straight
//! alpha, scaled to encoded pixels, ≤ 256 px), cached per (HCURSOR, scale) → CursorShapeRef for
//! repeats. Desktop Duplication frames don't contain the pointer, so the viewer draws it.

use crate::host::input::{normalize, PxRect};
use crate::host::log;
use crate::host::video::{color_cursor, fit_cursor, mono_cursor, CursorImage};
use crate::net::Sender;
use crate::protocol::HostMsg;
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// What the video thread tells the cursor thread.
pub struct CursorShared {
    /// The captured output (virtual-desktop pixels).
    pub output: Mutex<PxRect>,
    /// Encoded width / native width, as f32 bits.
    pub scale_bits: AtomicU32,
}

impl CursorShared {
    pub fn new(output: PxRect) -> CursorShared {
        CursorShared { output: Mutex::new(output), scale_bits: AtomicU32::new(1.0f32.to_bits()) }
    }
}

const MAX_CACHE: usize = 512;

pub fn run(tx: Sender, shared: Arc<CursorShared>, stop: Arc<AtomicBool>) {
    let mut cache: HashMap<(isize, u32), u32> = HashMap::new();
    let mut next_id = 1u32;
    let mut last_handle: Option<(isize, u32)> = None;
    let mut last_pos: Option<(f32, f32, bool)> = None;
    while !stop.load(Ordering::SeqCst) && !tx.is_closed() {
        std::thread::sleep(Duration::from_millis(8));
        let mut ci = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
        if unsafe { GetCursorInfo(&mut ci) }.is_err() {
            continue; // secure desktop: no cursor information
        }
        let out = *shared.output.lock().unwrap();
        let showing = ci.flags.0 & CURSOR_SHOWING.0 != 0 && !ci.hCursor.is_invalid();
        let (x, y, inside) = normalize(ci.ptScreenPos.x, ci.ptScreenPos.y, out);
        let visible = showing && inside;
        if showing {
            let scale_bits = shared.scale_bits.load(Ordering::SeqCst);
            let key = (ci.hCursor.0 as isize, scale_bits);
            if last_handle != Some(key) {
                last_handle = Some(key);
                let msg = match cache.get(&key) {
                    Some(&id) => Some(HostMsg::CursorShapeRef { shape_id: id }),
                    None => match unsafe { extract(ci.hCursor) } {
                        Some(img) => {
                            let img = fit_cursor(img, f32::from_bits(scale_bits));
                            if cache.len() >= MAX_CACHE {
                                cache.clear();
                            }
                            let id = next_id;
                            next_id = next_id.wrapping_add(1).max(1);
                            cache.insert(key, id);
                            Some(HostMsg::CursorShape {
                                shape_id: id,
                                w: img.w as u16,
                                h: img.h as u16,
                                hot_x: img.hot_x as u16,
                                hot_y: img.hot_y as u16,
                                bgra: img.bgra,
                            })
                        }
                        None => None,
                    },
                };
                if let Some(m) = msg {
                    if tx.send_plaintext(&m.encode()).is_err() {
                        break;
                    }
                }
            }
        }
        let pos = (x.clamp(0.0, 1.0), y.clamp(0.0, 1.0), visible);
        if last_pos != Some(pos) {
            last_pos = Some(pos);
            if tx.send_plaintext(&HostMsg::CursorPos { x: pos.0, y: pos.1, visible }.encode()).is_err() {
                break;
            }
        }
    }
}

/// 32-bpp top-down pixels of `bmp` (`w` x `h`).
unsafe fn dib(bmp: HBITMAP, w: i32, h: i32) -> Option<Vec<u8>> {
    let mut bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut buf = vec![0u8; (w * h * 4) as usize];
    let dc = GetDC(None);
    let n = GetDIBits(dc, bmp, 0, h as u32, Some(buf.as_mut_ptr() as *mut c_void), &mut bmi, DIB_RGB_COLORS);
    ReleaseDC(None, dc);
    (n > 0).then_some(buf)
}

/// The cursor's image (color with mask/alpha, or monochrome AND/XOR).
unsafe fn extract(h: HCURSOR) -> Option<CursorImage> {
    let mut ii = ICONINFO::default();
    if GetIconInfo(HICON(h.0), &mut ii).is_err() {
        return None;
    }
    let r = (|| {
        let mut bm = BITMAP::default();
        if GetObjectW(ii.hbmMask.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut BITMAP as *mut c_void)) == 0 {
            return None;
        }
        let (w, mh) = (bm.bmWidth, bm.bmHeight);
        if w <= 0 || mh <= 0 || w > 1024 || mh > 2048 {
            return None;
        }
        let color = !ii.hbmColor.is_invalid();
        let ch = if color { mh } else { mh / 2 };
        let mask = dib(ii.hbmMask, w, mh)?;
        let bgra = if color {
            let c = dib(ii.hbmColor, w, ch)?;
            color_cursor(&c, Some(&mask), w as u32, ch as u32)
        } else {
            mono_cursor(&mask, w as u32, ch as u32)
        };
        Some(CursorImage { w: w as u32, h: ch as u32, hot_x: ii.xHotspot.min(w as u32 - 1), hot_y: ii.yHotspot.min(ch as u32 - 1), bgra })
    })();
    if !ii.hbmMask.is_invalid() {
        let _ = DeleteObject(ii.hbmMask.into());
    }
    if !ii.hbmColor.is_invalid() {
        let _ = DeleteObject(ii.hbmColor.into());
    }
    if r.is_none() {
        log("cursor: couldn't read a cursor image");
    }
    r
}
