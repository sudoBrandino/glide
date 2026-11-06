//! D3D11 flip-model renderer. Decoded YUV layers (NV12/P010/AYUV/Y410/Y416) are converted
//! (BT.709 limited range) into a video-sized RGB canvas — whole frame or scissored update
//! rects — and the canvas is drawn aspect-fit into a waitable swap chain (max latency 1).

use super::d3d::Gpu;
use super::decoder::FrameTex;
use windows::core::{Interface, Result, PCSTR};
use windows::Win32::Foundation::{HANDLE, HWND, RECT};
use windows::Win32::Graphics::Direct3D::Fxc::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::Threading::WaitForSingleObjectEx;

const SHADER: &str = r#"
struct VO { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VO vs_main(uint id : SV_VertexID) {
    VO o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}

Texture2D<float4> t0 : register(t0);
Texture2D<float4> t1 : register(t1);
SamplerState smp : register(s0);
cbuffer Params : register(b0) { uint mode; float dim; uint2 pad; };

float4 ps_main(VO i) : SV_Target {
    float y, u, v;
    if (mode == 0) {          // NV12 / P010: Y plane + interleaved CbCr plane
        y = t0.Sample(smp, i.uv).r;
        float2 c = t1.Sample(smp, i.uv).rg;
        u = c.x; v = c.y;
    } else if (mode == 1) {   // AYUV viewed as RGBA: R=V G=U B=Y A=A
        float4 p = t0.Sample(smp, i.uv);
        y = p.b; u = p.g; v = p.r;
    } else {                  // Y410 / Y416: R=U G=Y B=V
        float4 p = t0.Sample(smp, i.uv);
        y = p.g; u = p.r; v = p.b;
    }
    // BT.709 limited range
    y = (y - 16.0 / 255.0) * (255.0 / 219.0);
    u = (u - 128.0 / 255.0) * (255.0 / 224.0);
    v = (v - 128.0 / 255.0) * (255.0 / 224.0);
    float3 rgb = float3(y + 1.5748 * v,
                        y - 0.187324 * u - 0.468124 * v,
                        y + 1.8556 * u);
    return float4(saturate(rgb), 1.0);
}

// Present: canvas (RGB) -> back buffer, scaled by the viewport.
float4 ps_copy(VO i) : SV_Target {
    return float4(t0.Sample(smp, i.uv).rgb * dim, 1.0);
}
"#;

fn compile(entry: &str, target: &str) -> Result<Vec<u8>> {
    unsafe {
        let entry_c = format!("{entry}\0");
        let target_c = format!("{target}\0");
        let mut code = None;
        let mut errors = None;
        let r = D3DCompile(
            SHADER.as_ptr() as *const _,
            SHADER.len(),
            PCSTR(b"glide.hlsl\0".as_ptr()),
            None,
            None,
            PCSTR(entry_c.as_ptr()),
            PCSTR(target_c.as_ptr()),
            D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut code,
            Some(&mut errors),
        );
        if let Err(e) = r {
            let msg = errors
                .map(|b: ID3DBlob| {
                    String::from_utf8_lossy(std::slice::from_raw_parts(b.GetBufferPointer() as *const u8, b.GetBufferSize()))
                        .into_owned()
                })
                .unwrap_or_default();
            return Err(windows::core::Error::new(e.code(), format!("shader {entry}: {msg}")));
        }
        let b: ID3DBlob = code.unwrap();
        Ok(std::slice::from_raw_parts(b.GetBufferPointer() as *const u8, b.GetBufferSize()).to_vec())
    }
}

pub struct Renderer {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    /// None = offscreen mode (no swap chain available, e.g. SSH session 0): we render into
    /// `offscreen` instead; used for headless smoke tests.
    swap: Option<IDXGISwapChain2>,
    offscreen: Option<ID3D11Texture2D>,
    waitable: HANDLE,
    rtv: Option<ID3D11RenderTargetView>,
    vs: ID3D11VertexShader,
    ps: ID3D11PixelShader,
    ps_copy: ID3D11PixelShader,
    sampler: ID3D11SamplerState,
    raster: ID3D11RasterizerState,
    /// Canvas (§3.1): video-sized RGB10A2 texture that decoded layers are converted into
    /// and that every present draws from.
    canvas: Option<(ID3D11Texture2D, ID3D11RenderTargetView, ID3D11ShaderResourceView, u32, u32)>,
    cb: ID3D11Buffer,
    cb_state: (u32, f32),
    /// Centered status text (e.g. "Waiting for host…"), rasterized with GDI.
    overlay: Option<(ID3D11ShaderResourceView, u32, u32)>,
    flags: DXGI_SWAP_CHAIN_FLAG,
    tearing: bool,
    pub size: (u32, u32),
}

impl Renderer {
    pub fn new(gpu: &Gpu, hwnd: HWND, w: u32, h: u32, want_tearing: bool) -> Result<Renderer> {
        unsafe {
            let factory = gpu.factory()?;
            let mut tearing = false;
            if want_tearing {
                if let Ok(f5) = factory.cast::<IDXGIFactory5>() {
                    let mut allow = windows::core::BOOL(0);
                    if f5
                        .CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, &mut allow as *mut _ as *mut _, 4)
                        .is_ok()
                    {
                        tearing = allow.as_bool();
                    }
                }
            }
            let mut flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
            if tearing {
                flags |= DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
            }
            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Width: w.max(1),
                Height: h.max(1),
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                Stereo: false.into(),
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                Scaling: DXGI_SCALING_NONE,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                AlphaMode: DXGI_ALPHA_MODE_IGNORE,
                Flags: flags.0 as u32,
            };
            let force_off = std::env::var("GLIDE_OFFSCREEN").map(|v| v == "1").unwrap_or(false);
            let sc = if force_off { None } else { Some(factory.CreateSwapChainForHwnd(&gpu.device, hwnd, &desc, None, None)) };
            let (swap, waitable) = match sc {
                Some(Ok(sc1)) => {
                    // We implement borderless fullscreen ourselves; keep DXGI's Alt+Enter out of it.
                    let _ = factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
                    let swap: IDXGISwapChain2 = sc1.cast()?;
                    swap.SetMaximumFrameLatency(1)?;
                    let waitable = swap.GetFrameLatencyWaitableObject();
                    (Some(swap), waitable)
                }
                Some(Err(e)) if e.code() != DXGI_ERROR_NOT_CURRENTLY_AVAILABLE => return Err(e),
                other => {
                    if let Some(Err(e)) = other {
                        eprintln!("warning: no swap chain ({e}); rendering offscreen (headless session?)");
                    }
                    (None, HANDLE::default())
                }
            };

            let vs_code = compile("vs_main", "vs_5_0")?;
            let ps_code = compile("ps_main", "ps_5_0")?;
            let ps_copy_code = compile("ps_copy", "ps_5_0")?;
            let mut vs = None;
            gpu.device.CreateVertexShader(&vs_code, None, Some(&mut vs))?;
            let mut ps = None;
            gpu.device.CreatePixelShader(&ps_code, None, Some(&mut ps))?;
            let mut ps_copy = None;
            gpu.device.CreatePixelShader(&ps_copy_code, None, Some(&mut ps_copy))?;
            let rd = D3D11_RASTERIZER_DESC {
                FillMode: D3D11_FILL_SOLID,
                CullMode: D3D11_CULL_NONE,
                DepthClipEnable: true.into(),
                ScissorEnable: true.into(),
                ..Default::default()
            };
            let mut raster = None;
            gpu.device.CreateRasterizerState(&rd, Some(&mut raster))?;

            let sd = D3D11_SAMPLER_DESC {
                Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                MaxLOD: f32::MAX,
                ..Default::default()
            };
            let mut sampler = None;
            gpu.device.CreateSamplerState(&sd, Some(&mut sampler))?;

            let bd = D3D11_BUFFER_DESC {
                ByteWidth: 16,
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                ..Default::default()
            };
            let zero = [0u32, 1.0f32.to_bits(), 0, 0];
            let init = D3D11_SUBRESOURCE_DATA { pSysMem: zero.as_ptr() as *const _, ..Default::default() };
            let mut cb = None;
            gpu.device.CreateBuffer(&bd, Some(&init), Some(&mut cb))?;

            let mut r = Renderer {
                device: gpu.device.clone(),
                context: gpu.context.clone(),
                swap,
                offscreen: None,
                waitable,
                rtv: None,
                vs: vs.unwrap(),
                ps: ps.unwrap(),
                ps_copy: ps_copy.unwrap(),
                sampler: sampler.unwrap(),
                raster: raster.unwrap(),
                canvas: None,
                cb: cb.unwrap(),
                cb_state: (0, 1.0),
                overlay: None,
                flags,
                tearing,
                size: (w.max(1), h.max(1)),
            };
            r.create_rtv()?;
            Ok(r)
        }
    }

    fn create_rtv(&mut self) -> Result<()> {
        unsafe {
            let bb: ID3D11Texture2D = match &self.swap {
                Some(s) => s.GetBuffer(0)?,
                None => {
                    let d = D3D11_TEXTURE2D_DESC {
                        Width: self.size.0,
                        Height: self.size.1,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_DEFAULT,
                        BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
                        ..Default::default()
                    };
                    let mut t = None;
                    self.device.CreateTexture2D(&d, None, Some(&mut t))?;
                    self.offscreen = t.clone();
                    t.unwrap()
                }
            };
            let mut rtv = None;
            self.device.CreateRenderTargetView(&bb, None, Some(&mut rtv))?;
            self.rtv = rtv;
        }
        Ok(())
    }

    pub fn resize(&mut self, w: u32, h: u32) -> Result<()> {
        let (w, h) = (w.max(1), h.max(1));
        if (w, h) == self.size {
            return Ok(());
        }
        unsafe {
            self.rtv = None;
            self.context.OMSetRenderTargets(None, None);
            self.context.Flush();
            if let Some(s) = &self.swap {
                s.ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, self.flags)?;
            }
        }
        self.size = (w, h);
        self.create_rtv()
    }

    /// Wait (bounded) until the swap chain can accept a new frame without queuing.
    pub fn wait_ready(&self, timeout_ms: u32) {
        if self.swap.is_some() {
            unsafe {
                WaitForSingleObjectEx(self.waitable, timeout_ms, true);
            }
        }
    }

    /// (Re)create the canvas at video size, cleared to black.
    pub fn reset_canvas(&mut self, w: u32, h: u32) -> Result<()> {
        let (w, h) = (w.max(2), h.max(2));
        unsafe {
            let d = D3D11_TEXTURE2D_DESC {
                Width: w,
                Height: h,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_R10G10B10A2_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                ..Default::default()
            };
            let mut t = None;
            self.device.CreateTexture2D(&d, None, Some(&mut t))?;
            let t: ID3D11Texture2D = t.unwrap();
            let mut rtv = None;
            self.device.CreateRenderTargetView(&t, None, Some(&mut rtv))?;
            let mut srv = None;
            self.device.CreateShaderResourceView(&t, None, Some(&mut srv))?;
            let rtv = rtv.unwrap();
            self.context.ClearRenderTargetView(&rtv, &[0.0, 0.0, 0.0, 1.0]);
            self.canvas = Some((t, rtv, srv.unwrap(), w, h));
        }
        Ok(())
    }

    pub fn canvas_size(&self) -> Option<(u32, u32)> {
        self.canvas.as_ref().map(|c| (c.3, c.4))
    }

    /// Convert a decoded YUV frame into the canvas. `rects` = None → whole frame;
    /// Some → only those (already clamped) rectangles, in canvas pixels.
    pub fn apply(&mut self, f: &FrameTex, rects: Option<&[(u32, u32, u32, u32)]>) {
        let Some((_, rtv, _, cw, ch)) = self.canvas.clone() else { return };
        unsafe {
            self.set_cb(f.fmt.shader_mode(), self.cb_state.1);
            let ctx = &self.context;
            ctx.OMSetRenderTargets(Some(&[Some(rtv)]), None);
            // The decoded frame maps 1:1 onto the canvas.
            let vp = D3D11_VIEWPORT { TopLeftX: 0.0, TopLeftY: 0.0, Width: cw as f32, Height: ch as f32, MinDepth: 0.0, MaxDepth: 1.0 };
            ctx.RSSetViewports(Some(&[vp]));
            ctx.RSSetState(&self.raster);
            ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx.IASetInputLayout(None);
            ctx.VSSetShader(&self.vs, None);
            ctx.PSSetShader(&self.ps, None);
            ctx.PSSetShaderResources(0, Some(&[Some(f.srv0.clone()), f.srv1.clone()]));
            ctx.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
            ctx.PSSetConstantBuffers(0, Some(&[Some(self.cb.clone())]));
            match rects {
                None => {
                    ctx.RSSetScissorRects(Some(&[RECT { left: 0, top: 0, right: cw as i32, bottom: ch as i32 }]));
                    ctx.Draw(3, 0);
                }
                Some(rs) => {
                    for &(x, y, w, h) in rs {
                        let r = RECT {
                            left: x.min(cw) as i32,
                            top: y.min(ch) as i32,
                            right: (x + w).min(cw) as i32,
                            bottom: (y + h).min(ch) as i32,
                        };
                        if r.right > r.left && r.bottom > r.top {
                            ctx.RSSetScissorRects(Some(&[r]));
                            ctx.Draw(3, 0);
                        }
                    }
                }
            }
            ctx.PSSetShaderResources(0, Some(&[None, None]));
        }
    }

    fn set_cb(&mut self, mode: u32, dim: f32) {
        if self.cb_state != (mode, dim) {
            let data = [mode, dim.to_bits(), 0, 0];
            unsafe {
                self.context.UpdateSubresource(&self.cb, 0, None, data.as_ptr() as *const _, 0, 0);
            }
            self.cb_state = (mode, dim);
        }
    }

    /// Set (or clear) the centered status text. `px` is the font height in pixels.
    pub fn set_overlay(&mut self, text: Option<&str>, px: i32) -> Result<()> {
        self.overlay = None;
        let Some(text) = text else { return Ok(()) };
        use windows::Win32::Foundation::SIZE;
        use windows::Win32::Graphics::Gdi::*;
        let wide: Vec<u16> = text.encode_utf16().collect();
        unsafe {
            let hdc = CreateCompatibleDC(None);
            let font = CreateFontW(
                -px,
                0,
                0,
                0,
                FW_SEMIBOLD.0 as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                ANTIALIASED_QUALITY,
                0,
                windows::core::w!("Segoe UI"),
            );
            let old_font = SelectObject(hdc, font.into());
            let mut sz = SIZE::default();
            let _ = GetTextExtentPoint32W(hdc, &wide, &mut sz);
            let (padx, pady) = (px, px / 2);
            let (w, h) = ((sz.cx + 2 * padx).max(1) as u32, (sz.cy + 2 * pady).max(1) as u32);
            let bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w as i32,
                    biHeight: -(h as i32),
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
            let bmp = CreateDIBSection(Some(hdc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0);
            let result = match bmp {
                Ok(bmp) => {
                    let old_bmp = SelectObject(hdc, bmp.into());
                    let px_slice = std::slice::from_raw_parts_mut(bits as *mut u32, (w * h) as usize);
                    px_slice.fill(0xFF22_2226); // dark panel (BGRA: 26 22 22 FF)
                    SetBkMode(hdc, TRANSPARENT);
                    SetTextColor(hdc, windows::Win32::Foundation::COLORREF(0x00F2_F2F2));
                    let _ = TextOutW(hdc, padx, pady, &wide);
                    let _ = GdiFlush();
                    let mut data: Vec<u32> = px_slice.iter().map(|p| p | 0xFF00_0000).collect();
                    data.shrink_to_fit();
                    SelectObject(hdc, old_bmp);
                    let _ = DeleteObject(bmp.into());
                    let d = D3D11_TEXTURE2D_DESC {
                        Width: w,
                        Height: h,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_IMMUTABLE,
                        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                        ..Default::default()
                    };
                    let init = D3D11_SUBRESOURCE_DATA { pSysMem: data.as_ptr() as *const _, SysMemPitch: w * 4, SysMemSlicePitch: 0 };
                    let mut t = None;
                    let r = self.device.CreateTexture2D(&d, Some(&init), Some(&mut t)).and_then(|_| {
                        let t: ID3D11Texture2D = t.unwrap();
                        let mut srv = None;
                        self.device.CreateShaderResourceView(&t, None, Some(&mut srv))?;
                        Ok(srv.unwrap())
                    });
                    r.map(|srv| self.overlay = Some((srv, w, h)))
                }
                Err(e) => Err(e),
            };
            SelectObject(hdc, old_font);
            let _ = DeleteObject(font.into());
            let _ = DeleteDC(hdc);
            result
        }
    }

    /// Draw the canvas letterboxed into `rect` (x, y, w, h in back-buffer pixels), multiplied
    /// by `dim`, plus the status overlay if set, and present.
    pub fn present(&mut self, rect: (i32, i32, i32, i32), dim: f32) -> Result<()> {
        unsafe {
            let Some(rtv) = self.rtv.clone() else { return Ok(()) };
            let bg = if self.canvas.is_some() { 0.0 } else { 0.06 };
            self.context.ClearRenderTargetView(&rtv, &[bg, bg, bg * 1.1, 1.0]);
            let mode = self.cb_state.0;
            self.set_cb(mode, dim);
            let ctx = &self.context;
            if let Some((_, _, srv, _, _)) = self.canvas.clone() {
                ctx.OMSetRenderTargets(Some(&[Some(rtv.clone())]), None);
                let vp = D3D11_VIEWPORT {
                    TopLeftX: rect.0 as f32,
                    TopLeftY: rect.1 as f32,
                    Width: rect.2 as f32,
                    Height: rect.3 as f32,
                    MinDepth: 0.0,
                    MaxDepth: 1.0,
                };
                ctx.RSSetViewports(Some(&[vp]));
                ctx.RSSetState(&self.raster);
                ctx.RSSetScissorRects(Some(&[RECT { left: rect.0, top: rect.1, right: rect.0 + rect.2, bottom: rect.1 + rect.3 }]));
                ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                ctx.IASetInputLayout(None);
                ctx.VSSetShader(&self.vs, None);
                ctx.PSSetShader(&self.ps_copy, None);
                ctx.PSSetShaderResources(0, Some(&[Some(srv)]));
                ctx.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
                ctx.PSSetConstantBuffers(0, Some(&[Some(self.cb.clone())]));
                ctx.Draw(3, 0);
                ctx.PSSetShaderResources(0, Some(&[None]));
            }
            if let Some((srv, w, h)) = self.overlay.clone() {
                let (bw, bh) = self.size;
                let (x, y) = ((bw as i32 - w as i32) / 2, (bh as i32 - h as i32) / 2);
                self.set_cb(mode, 1.0);
                let ctx = &self.context;
                ctx.OMSetRenderTargets(Some(&[Some(rtv.clone())]), None);
                let vp = D3D11_VIEWPORT { TopLeftX: x as f32, TopLeftY: y as f32, Width: w as f32, Height: h as f32, MinDepth: 0.0, MaxDepth: 1.0 };
                ctx.RSSetViewports(Some(&[vp]));
                ctx.RSSetState(&self.raster);
                ctx.RSSetScissorRects(Some(&[RECT { left: x, top: y, right: x + w as i32, bottom: y + h as i32 }]));
                ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                ctx.IASetInputLayout(None);
                ctx.VSSetShader(&self.vs, None);
                ctx.PSSetShader(&self.ps_copy, None);
                ctx.PSSetShaderResources(0, Some(&[Some(srv)]));
                ctx.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
                ctx.PSSetConstantBuffers(0, Some(&[Some(self.cb.clone())]));
                ctx.Draw(3, 0);
                ctx.PSSetShaderResources(0, Some(&[None]));
            }
            let ctx = &self.context;
            match &self.swap {
                Some(s) => {
                    let flags = if self.tearing { DXGI_PRESENT_ALLOW_TEARING } else { DXGI_PRESENT(0) };
                    s.Present(0, flags).ok()
                }
                None => {
                    ctx.Flush();
                    Ok(())
                }
            }
        }
    }
}

impl Renderer {
    pub fn is_offscreen(&self) -> bool {
        self.swap.is_none()
    }

    /// Write the current back buffer / offscreen target to a 32-bit BMP (diagnostics).
    pub fn dump_bmp(&self, path: &str) -> Result<()> {
        unsafe {
            let src: ID3D11Texture2D = match (&self.swap, &self.offscreen) {
                (Some(s), _) => s.GetBuffer(0)?,
                (None, Some(t)) => t.clone(),
                _ => return Ok(()),
            };
            let (w, h) = self.size;
            let d = D3D11_TEXTURE2D_DESC {
                Width: w,
                Height: h,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                ..Default::default()
            };
            let mut st = None;
            self.device.CreateTexture2D(&d, None, Some(&mut st))?;
            let st = st.unwrap();
            self.context.CopyResource(&st, &src);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(&st, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
            let mut out = Vec::with_capacity(54 + (w * h * 4) as usize);
            let size = 54 + w * h * 4;
            out.extend_from_slice(b"BM");
            out.extend_from_slice(&size.to_le_bytes());
            out.extend_from_slice(&[0, 0, 0, 0]);
            out.extend_from_slice(&54u32.to_le_bytes());
            out.extend_from_slice(&40u32.to_le_bytes());
            out.extend_from_slice(&(w as i32).to_le_bytes());
            out.extend_from_slice(&(-(h as i32)).to_le_bytes());
            out.extend_from_slice(&1u16.to_le_bytes());
            out.extend_from_slice(&32u16.to_le_bytes());
            out.extend_from_slice(&[0u8; 24]);
            for y in 0..h as usize {
                let row = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), (w * 4) as usize);
                out.extend_from_slice(row);
            }
            self.context.Unmap(&st, 0);
            std::fs::write(path, out).map_err(|e| windows::core::Error::new(windows::Win32::Foundation::E_FAIL, e.to_string()))
        }
    }
}

impl Drop for Renderer {
    fn drop(&mut self) {
        if !self.waitable.is_invalid() && !self.waitable.0.is_null() {
            unsafe {
                let _ = windows::Win32::Foundation::CloseHandle(self.waitable);
            }
        }
    }
}
