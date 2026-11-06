//! Host cursor shapes → Win32 HCURSOR (CreateIconIndirect from straight-alpha BGRA),
//! optionally rescaled to the view scale.

use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone)]
pub struct CursorImage {
    pub w: u32,
    pub h: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    /// BGRA, straight alpha, top-down.
    pub bgra: Vec<u8>,
}

/// Resample (bilinear, in premultiplied space) to `scale`; returns a new straight-alpha image.
pub fn scale_image(img: &CursorImage, scale: f32) -> CursorImage {
    if (scale - 1.0).abs() < 0.01 || img.w == 0 || img.h == 0 {
        return img.clone();
    }
    let nw = ((img.w as f32 * scale).round() as u32).clamp(1, 256);
    let nh = ((img.h as f32 * scale).round() as u32).clamp(1, 256);
    let sx = img.w as f32 / nw as f32;
    let sy = img.h as f32 / nh as f32;
    let px = |x: i64, y: i64| -> [f32; 4] {
        let x = x.clamp(0, img.w as i64 - 1) as usize;
        let y = y.clamp(0, img.h as i64 - 1) as usize;
        let i = (y * img.w as usize + x) * 4;
        let a = img.bgra[i + 3] as f32 / 255.0;
        [img.bgra[i] as f32 * a, img.bgra[i + 1] as f32 * a, img.bgra[i + 2] as f32 * a, a]
    };
    let mut out = vec![0u8; (nw * nh * 4) as usize];
    for y in 0..nh {
        for x in 0..nw {
            // When downscaling by an integer factor, average the covered block (box filter);
            // otherwise bilinear.
            let fx = (x as f32 + 0.5) * sx - 0.5;
            let fy = (y as f32 + 0.5) * sy - 0.5;
            let mut acc = [0f32; 4];
            let (bx, by) = (sx.max(1.0).ceil() as i64, sy.max(1.0).ceil() as i64);
            let mut wsum = 0f32;
            if bx > 1 || by > 1 {
                let x0 = (x as f32 * sx).floor() as i64;
                let y0 = (y as f32 * sy).floor() as i64;
                for yy in y0..y0 + by {
                    for xx in x0..x0 + bx {
                        let p = px(xx, yy);
                        for c in 0..4 {
                            acc[c] += p[c];
                        }
                        wsum += 1.0;
                    }
                }
            } else {
                let x0 = fx.floor();
                let y0 = fy.floor();
                let (tx, ty) = (fx - x0, fy - y0);
                for (dx, dy, w) in [(0, 0, (1.0 - tx) * (1.0 - ty)), (1, 0, tx * (1.0 - ty)), (0, 1, (1.0 - tx) * ty), (1, 1, tx * ty)] {
                    let p = px(x0 as i64 + dx, y0 as i64 + dy);
                    for c in 0..4 {
                        acc[c] += p[c] * w;
                    }
                    wsum += w;
                }
            }
            let a = acc[3] / wsum;
            let i = ((y * nw + x) * 4) as usize;
            if a > 0.0 {
                for c in 0..3 {
                    out[i + c] = (acc[c] / wsum / a).round().clamp(0.0, 255.0) as u8;
                }
            }
            out[i + 3] = (a * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
    CursorImage {
        w: nw,
        h: nh,
        hot_x: ((img.hot_x as f32 * nw as f32 / img.w as f32) as u32).min(nw - 1),
        hot_y: ((img.hot_y as f32 * nh as f32 / img.h as f32) as u32).min(nh - 1),
        bgra: out,
    }
}

/// Build an HCURSOR. Windows expects a 32bpp DIB with straight (non-premultiplied) alpha
/// for icons/cursors, which is exactly what the protocol sends.
pub fn create_cursor(img: &CursorImage) -> Option<HCURSOR> {
    if img.w == 0 || img.h == 0 || img.bgra.len() < (img.w * img.h * 4) as usize {
        return None;
    }
    unsafe {
        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: img.w as i32,
                biHeight: -(img.h as i32), // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let color = CreateDIBSection(None, &bmi, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
        std::ptr::copy_nonoverlapping(img.bgra.as_ptr(), bits as *mut u8, (img.w * img.h * 4) as usize);
        // Monochrome AND mask: all zero (the alpha channel decides transparency).
        let mask_bytes = vec![0u8; (img.w.div_ceil(16) * 2 * img.h) as usize];
        let mask = CreateBitmap(img.w as i32, img.h as i32, 1, 1, Some(mask_bytes.as_ptr() as *const _));
        let ii = ICONINFO {
            fIcon: false.into(),
            xHotspot: img.hot_x,
            yHotspot: img.hot_y,
            hbmMask: mask,
            hbmColor: color,
        };
        let icon = CreateIconIndirect(&ii).ok();
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon.map(|h| HCURSOR(h.0))
    }
}

pub fn destroy_cursor(c: HCURSOR) {
    unsafe {
        let _ = DestroyCursor(c);
    }
}
