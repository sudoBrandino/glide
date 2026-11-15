//! DXGI Desktop Duplication of the primary output.
//!
//! - The D3D11 device is created on the adapter that drives the output (duplication requires it;
//!   on hybrid-GPU laptops that is usually the integrated GPU).
//! - `IDXGIOutput5::DuplicateOutput1` (BGRA only) is tried first, then `IDXGIOutput1::DuplicateOutput`.
//! - Each updated frame is copied into our own BGRA texture right away and the duplication frame is
//!   released, so the GPU-side copy can be re-encoded later (keyframe on request) without a new frame.
//! - DXGI_ERROR_ACCESS_LOST (mode change, desktop switch, full-screen app) → the caller re-creates
//!   the duplicator. On the secure desktop creation fails with E_ACCESSDENIED until it goes away.

use super::hr;
use crate::host::input::PxRect;
use windows::core::{Interface, Result};
use windows::Win32::Foundation::{HMODULE, LUID, POINT};
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::{MonitorFromPoint, HMONITOR, MONITOR_DEFAULTTOPRIMARY};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

/// The output being streamed.
pub struct Output {
    pub adapter: IDXGIAdapter1,
    pub output: IDXGIOutput1,
    /// Desktop rectangle in virtual-desktop pixels (rotated orientation).
    pub rect: PxRect,
    pub rotation: DXGI_MODE_ROTATION,
    pub monitor: HMONITOR,
    pub luid: LUID,
    pub adapter_name: String,
    pub device_name: String,
}

impl Output {
    /// The monitor's DPI scale (1.0 = 96 dpi): VideoConfig.scale.
    pub fn dpi_scale(&self) -> f32 {
        unsafe {
            let (mut x, mut y) = (0u32, 0u32);
            if GetDpiForMonitor(self.monitor, MDT_EFFECTIVE_DPI, &mut x, &mut y).is_ok() && x > 0 {
                x as f32 / 96.0
            } else {
                1.0
            }
        }
    }
}

fn wstr(w: &[u16]) -> String {
    let n = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..n])
}

/// Finds the primary output (the monitor at the desktop origin) and its adapter.
pub fn primary_output() -> Result<Output> {
    unsafe {
        let primary = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let mut first: Option<Output> = None;
        let mut a = 0;
        while let Ok(adapter) = factory.EnumAdapters1(a) {
            a += 1;
            let ad = adapter.GetDesc1()?;
            let mut o = 0;
            while let Ok(out) = adapter.EnumOutputs(o) {
                o += 1;
                let d = out.GetDesc()?;
                if !d.AttachedToDesktop.as_bool() {
                    continue;
                }
                let r = d.DesktopCoordinates;
                let info = Output {
                    adapter: adapter.clone(),
                    output: out.cast()?,
                    rect: PxRect { left: r.left, top: r.top, right: r.right, bottom: r.bottom },
                    rotation: d.Rotation,
                    monitor: d.Monitor,
                    luid: ad.AdapterLuid,
                    adapter_name: wstr(&ad.Description),
                    device_name: wstr(&d.DeviceName),
                };
                if d.Monitor == primary {
                    return Ok(info);
                }
                if first.is_none() {
                    first = Some(info);
                }
            }
        }
        first.ok_or_else(|| windows::core::Error::new(DXGI_ERROR_NOT_FOUND, "no output attached to the desktop"))
    }
}

/// D3D11 device on the output's adapter, with video support, multithread protection and an MF
/// DXGI device manager (shared with the encoder MFT).
pub struct Device {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub manager: IMFDXGIDeviceManager,
}

impl Device {
    pub fn new(adapter: &IDXGIAdapter1) -> Result<Device> {
        crate::win::d3d::mf_startup()?;
        unsafe {
            let mut device = None;
            let mut context = None;
            let levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1];
            let adapter: IDXGIAdapter = adapter.cast()?;
            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
            let device: ID3D11Device = device.unwrap();
            let context: ID3D11DeviceContext = context.unwrap();
            // The encoder MFT uses the device from its own threads.
            let mt: ID3D11Multithread = context.cast()?;
            let _ = mt.SetMultithreadProtected(true);
            let mut token = 0u32;
            let mut manager = None;
            MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
            let manager: IMFDXGIDeviceManager = manager.unwrap();
            manager.ResetDevice(&device, token)?;
            Ok(Device { device, context, manager })
        }
    }
}

pub enum Acquired {
    /// Nothing new on screen within the timeout (or only the pointer moved).
    NoChange,
    /// `Duplicator::frame` holds a new image.
    Updated,
}

/// One Desktop Duplication session.
pub struct Duplicator {
    dup: IDXGIOutputDuplication,
    context: ID3D11DeviceContext,
    device: ID3D11Device,
    /// Our copy of the latest desktop image (BGRA, texture dimensions = unrotated mode).
    pub frame: Option<ID3D11Texture2D>,
    /// Desktop texture size (panel orientation).
    pub tex_w: u32,
    pub tex_h: u32,
    pub rotation: DXGI_MODE_ROTATION,
}

impl Duplicator {
    pub fn new(dev: &Device, out: &Output) -> Result<Duplicator> {
        unsafe {
            let dup = match out.output.cast::<IDXGIOutput5>() {
                Ok(o5) => match o5.DuplicateOutput1(&dev.device, 0, &[DXGI_FORMAT_B8G8R8A8_UNORM]) {
                    Ok(d) => d,
                    Err(e) => {
                        crate::host::log(&format!("capture: DuplicateOutput1 failed ({}); trying DuplicateOutput", hr(&e)));
                        out.output.DuplicateOutput(&dev.device)?
                    }
                },
                Err(_) => out.output.DuplicateOutput(&dev.device)?,
            };
            let d = dup.GetDesc();
            Ok(Duplicator {
                dup,
                context: dev.context.clone(),
                device: dev.device.clone(),
                frame: None,
                tex_w: d.ModeDesc.Width,
                tex_h: d.ModeDesc.Height,
                rotation: d.Rotation,
            })
        }
    }

    /// Waits up to `timeout_ms` for a new desktop image. Err(DXGI_ERROR_ACCESS_LOST etc.) means
    /// this duplicator is dead: drop it and create a new one.
    pub fn acquire(&mut self, timeout_ms: u32) -> Result<Acquired> {
        unsafe {
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut res: Option<IDXGIResource> = None;
            match self.dup.AcquireNextFrame(timeout_ms, &mut info, &mut res) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(Acquired::NoChange),
                Err(e) => return Err(e),
            }
            let r = self.take(&info, res);
            let _ = self.dup.ReleaseFrame();
            r
        }
    }

    unsafe fn take(&mut self, info: &DXGI_OUTDUPL_FRAME_INFO, res: Option<IDXGIResource>) -> Result<Acquired> {
        // AccumulatedFrames == 0 / LastPresentTime == 0: only the pointer changed.
        if info.AccumulatedFrames == 0 || info.LastPresentTime == 0 {
            return Ok(Acquired::NoChange);
        }
        let Some(res) = res else { return Ok(Acquired::NoChange) };
        let src: ID3D11Texture2D = res.cast()?;
        let mut sd = D3D11_TEXTURE2D_DESC::default();
        src.GetDesc(&mut sd);
        let reuse = self.frame.as_ref().is_some_and(|f| {
            let mut fd = D3D11_TEXTURE2D_DESC::default();
            f.GetDesc(&mut fd);
            fd.Width == sd.Width && fd.Height == sd.Height && fd.Format == sd.Format
        });
        if !reuse {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: sd.Width,
                Height: sd.Height,
                MipLevels: 1,
                ArraySize: 1,
                Format: sd.Format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_RENDER_TARGET.0) as u32,
                CPUAccessFlags: 0,
                MiscFlags: 0,
            };
            let mut t = None;
            self.device.CreateTexture2D(&desc, None, Some(&mut t))?;
            self.frame = t;
            self.tex_w = sd.Width;
            self.tex_h = sd.Height;
            crate::host::log(&format!("capture: desktop texture {}x{} format {}", sd.Width, sd.Height, sd.Format.0));
        }
        if let Some(f) = &self.frame {
            self.context.CopyResource(f, &src);
        }
        Ok(Acquired::Updated)
    }
}
