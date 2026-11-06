//! D3D11 flip-model renderer. Decoded YUV layers (NV12/P010/AYUV/Y410/Y416) are converted
//! (BT.709 limited range) into a video-sized RGB canvas — whole frame or scissored update
//! rects — and the canvas is drawn aspect-fit into a waitable swap chain (max latency 1).
//! Text (status line, stats HUD, hotkey toasts) is rasterized with GDI into small premultiplied
//! BGRA textures only when it changes, and alpha-blended 1:1 on top at present time.

use super::d3d::Gpu;
use super::decoder::FrameTex;
use windows::core::{Interface, Result, PCSTR, PCWSTR};
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

// Text panels: premultiplied BGRA drawn 1:1, faded by `dim` (opacity).
float4 ps_overlay(VO i) : SV_Target {
    return t0.Sample(smp, i.uv) * dim;
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
    ps_overlay: ID3D11PixelShader,
    /// Premultiplied-alpha blending for text panels.
    blend: ID3D11BlendState,
    sampler: ID3D11SamplerState,
    raster: ID3D11RasterizerState,
    /// Canvas (§3.1): video-sized RGB10A2 texture that decoded layers are converted into
    /// and that every present draws from.
    canvas: Option<(ID3D11Texture2D, ID3D11RenderTargetView, ID3D11ShaderResourceView, u32, u32)>,
    cb: ID3D11Buffer,
    cb_state: (u32, f32),
    /// Centered status text (e.g. "Waiting for host…").
    overlay: Option<Panel>,
    /// Stats HUD, top-left.
    hud: Option<Panel>,
    /// Hotkey toast, bottom-center, with its current opacity.
    toast: Option<(Panel, f32)>,
    /// Connection bar tab, top-center, drawn `bar.1` px above the top edge (hides the top corners).
    bar: Option<(Panel, i32)>,
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
            let ps_overlay_code = compile("ps_overlay", "ps_5_0")?;
            let mut vs = None;
            gpu.device.CreateVertexShader(&vs_code, None, Some(&mut vs))?;
            let mut ps = None;
            gpu.device.CreatePixelShader(&ps_code, None, Some(&mut ps))?;
            let mut ps_copy = None;
            gpu.device.CreatePixelShader(&ps_copy_code, None, Some(&mut ps_copy))?;
            let mut ps_overlay = None;
            gpu.device.CreatePixelShader(&ps_overlay_code, None, Some(&mut ps_overlay))?;
            let mut bd = D3D11_BLEND_DESC::default();
            bd.RenderTarget[0] = D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: true.into(),
                SrcBlend: D3D11_BLEND_ONE,
                DestBlend: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            };
            let mut blend = None;
            gpu.device.CreateBlendState(&bd, Some(&mut blend))?;
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
                ps_overlay: ps_overlay.unwrap(),
                blend: blend.unwrap(),
                sampler: sampler.unwrap(),
                raster: raster.unwrap(),
                canvas: None,
                cb: cb.unwrap(),
                cb_state: (0, 1.0),
                overlay: None,
                hud: None,
                toast: None,
                bar: None,
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
        self.overlay = Some(self.make_panel(&[text], px, &PanelStyle::STATUS)?);
        Ok(())
    }

    /// Set (or clear) the stats HUD lines.
    pub fn set_hud(&mut self, lines: Option<&[String]>, px: i32) -> Result<()> {
        self.hud = None;
        let Some(lines) = lines.filter(|l| !l.is_empty()) else { return Ok(()) };
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        self.hud = Some(self.make_panel(&refs, px, &PanelStyle::HUD)?);
        Ok(())
    }

    /// Set (or clear) the toast; it starts fully opaque.
    pub fn set_toast(&mut self, text: Option<&str>, px: i32) -> Result<()> {
        self.toast = None;
        let Some(text) = text else { return Ok(()) };
        self.toast = Some((self.make_panel(&[text], px, &PanelStyle::TOAST)?, 1.0));
        Ok(())
    }

    /// Set (or clear) the connection-bar tab. Returns the visible size (w, h) in pixels.
    pub fn set_bar(&mut self, text: Option<&str>, px: i32) -> Result<Option<(u32, u32)>> {
        self.bar = None;
        let Some(text) = text else { return Ok(None) };
        let p = self.make_panel(&[text], px, &PanelStyle::BAR)?;
        // Push the rounded top corners (and the extra top padding) above the window edge: only
        // the bottom corners show.
        let off = (px.max(8) as f32 * PanelStyle::BAR.pad_top) as i32;
        let size = (p.w, p.h - off as u32);
        self.bar = Some((p, off));
        Ok(Some(size))
    }

    pub fn set_toast_opacity(&mut self, a: f32) {
        if let Some(t) = self.toast.as_mut() {
            t.1 = a.clamp(0.0, 1.0);
        }
    }

    /// Rasterize `lines` with GDI (grayscale AA, white on black → coverage), then compose a
    /// premultiplied BGRA rounded panel and upload it as an immutable texture.
    fn make_panel(&self, lines: &[&str], px: i32, st: &PanelStyle) -> Result<Panel> {
        use windows::Win32::Foundation::SIZE;
        use windows::Win32::Graphics::Gdi::*;
        let px = px.max(8);
        let wides: Vec<Vec<u16>> = lines.iter().map(|l| l.encode_utf16().collect()).collect();
        unsafe {
            let hdc = CreateCompatibleDC(None);
            let font = CreateFontW(
                -px,
                0,
                0,
                0,
                st.weight,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                ANTIALIASED_QUALITY,
                0,
                st.face,
            );
            let old_font = SelectObject(hdc, font.into());
            let mut tm = TEXTMETRICW::default();
            let _ = GetTextMetricsW(hdc, &mut tm);
            let line_h = tm.tmHeight + (px as f32 * st.line_gap) as i32;
            let mut text_w = 0;
            for wl in &wides {
                let mut sz = SIZE::default();
                let _ = GetTextExtentPoint32W(hdc, wl, &mut sz);
                text_w = text_w.max(sz.cx);
            }
            let (padx, pady) = ((px as f32 * st.pad.0) as i32, (px as f32 * st.pad.1) as i32);
            let text_h = line_h * (wides.len() as i32 - 1) + tm.tmHeight;
            let extra = (px as f32 * st.pad_top) as i32;
            let (w, h) = ((text_w + 2 * padx).max(1) as u32, (text_h + 2 * pady + extra).max(1) as u32);
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
                    let cov = std::slice::from_raw_parts_mut(bits as *mut u32, (w * h) as usize);
                    cov.fill(0);
                    SetBkMode(hdc, TRANSPARENT);
                    SetTextColor(hdc, windows::Win32::Foundation::COLORREF(0x00FF_FFFF));
                    for (i, wl) in wides.iter().enumerate() {
                        let _ = TextOutW(hdc, padx, extra + pady + i as i32 * line_h, wl);
                    }
                    let _ = GdiFlush();
                    let data = compose_panel(cov, w, h, (px as f32 * st.radius).min(h as f32 / 2.0), st);
                    SelectObject(hdc, old_bmp);
                    let _ = DeleteObject(bmp.into());
                    self.upload_bgra(&data, w, h)
                }
                Err(e) => Err(e),
            };
            SelectObject(hdc, old_font);
            let _ = DeleteObject(font.into());
            let _ = DeleteDC(hdc);
            result
        }
    }

    fn upload_bgra(&self, data: &[u32], w: u32, h: u32) -> Result<Panel> {
        unsafe {
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
            self.device.CreateTexture2D(&d, Some(&init), Some(&mut t))?;
            let t: ID3D11Texture2D = t.unwrap();
            let mut srv = None;
            self.device.CreateShaderResourceView(&t, None, Some(&mut srv))?;
            Ok(Panel { srv: srv.unwrap(), w, h })
        }
    }

    /// Alpha-blend a panel 1:1 at (x, y) in back-buffer pixels.
    fn draw_panel(&mut self, rtv: &ID3D11RenderTargetView, p: &Panel, x: i32, y: i32, opacity: f32) {
        let mode = self.cb_state.0;
        self.set_cb(mode, opacity);
        let ctx = &self.context;
        unsafe {
            ctx.OMSetRenderTargets(Some(&[Some(rtv.clone())]), None);
            ctx.OMSetBlendState(&self.blend, None, 0xFFFF_FFFF);
            let vp = D3D11_VIEWPORT { TopLeftX: x as f32, TopLeftY: y as f32, Width: p.w as f32, Height: p.h as f32, MinDepth: 0.0, MaxDepth: 1.0 };
            ctx.RSSetViewports(Some(&[vp]));
            ctx.RSSetState(&self.raster);
            ctx.RSSetScissorRects(Some(&[RECT { left: x, top: y, right: x + p.w as i32, bottom: y + p.h as i32 }]));
            ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx.IASetInputLayout(None);
            ctx.VSSetShader(&self.vs, None);
            ctx.PSSetShader(&self.ps_overlay, None);
            ctx.PSSetShaderResources(0, Some(&[Some(p.srv.clone())]));
            ctx.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
            ctx.PSSetConstantBuffers(0, Some(&[Some(self.cb.clone())]));
            ctx.Draw(3, 0);
            ctx.PSSetShaderResources(0, Some(&[None]));
            ctx.OMSetBlendState(None, None, 0xFFFF_FFFF);
        }
    }

    /// Draw the canvas letterboxed into `rect` (x, y, w, h in back-buffer pixels), multiplied
    /// by `dim`, then the HUD, toast and status panels if set, and present.
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
            let (bw, bh) = (self.size.0 as i32, self.size.1 as i32);
            if let Some(p) = self.hud.clone() {
                let m = (p.h as i32 / 12).clamp(8, 24);
                self.draw_panel(&rtv, &p, m, m, 1.0);
            }
            if let Some((p, a)) = self.toast.clone() {
                if a > 0.0 {
                    let y = (bh - p.h as i32 - bh / 10).max(0);
                    self.draw_panel(&rtv, &p, (bw - p.w as i32) / 2, y, a);
                }
            }
            if let Some(p) = self.overlay.clone() {
                self.draw_panel(&rtv, &p, (bw - p.w as i32) / 2, (bh - p.h as i32) / 2, 1.0);
            }
            if let Some((p, off)) = self.bar.clone() {
                self.draw_panel(&rtv, &p, (bw - p.w as i32) / 2, -off, 1.0);
            }
            self.set_cb(mode, dim);
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

#[derive(Clone)]
struct Panel {
    srv: ID3D11ShaderResourceView,
    w: u32,
    h: u32,
}

/// Look of a text panel. Sizes are fractions of the font pixel height.
pub struct PanelStyle {
    face: PCWSTR,
    weight: i32,
    fg: [f32; 3],
    bg: [f32; 3],
    bg_alpha: f32,
    radius: f32,
    pad: (f32, f32),
    line_gap: f32,
    /// Extra space above the text (the bar draws this part above the window edge).
    pad_top: f32,
}

impl PanelStyle {
    const STATUS: PanelStyle = PanelStyle {
        face: windows::core::w!("Segoe UI"),
        weight: 600,
        fg: [0.95, 0.95, 0.95],
        bg: [0.133, 0.133, 0.149],
        bg_alpha: 0.96,
        radius: 0.5,
        pad: (1.0, 0.5),
        line_gap: 0.2,
        pad_top: 0.0,
    };
    const HUD: PanelStyle = PanelStyle {
        face: windows::core::w!("Consolas"),
        weight: 400,
        fg: [0.93, 0.95, 0.97],
        bg: [0.0, 0.0, 0.0],
        bg_alpha: 0.62,
        radius: 0.45,
        pad: (0.75, 0.5),
        line_gap: 0.18,
        pad_top: 0.0,
    };
    pub(crate) const BAR: PanelStyle = PanelStyle {
        face: windows::core::w!("Segoe UI"),
        weight: 600,
        fg: [0.96, 0.97, 1.0],
        bg: [0.09, 0.10, 0.13],
        bg_alpha: 0.88,
        radius: 0.6,
        pad: (1.0, 0.4),
        line_gap: 0.2,
        pad_top: 0.6,
    };
    const TOAST: PanelStyle = PanelStyle {
        face: windows::core::w!("Segoe UI"),
        weight: 600,
        fg: [1.0, 1.0, 1.0],
        bg: [0.08, 0.08, 0.1],
        bg_alpha: 0.82,
        radius: 0.9,
        pad: (1.1, 0.55),
        line_gap: 0.2,
        pad_top: 0.0,
    };
}

/// Text coverage (GDI white-on-black, grayscale AA) → premultiplied BGRA rounded panel.
fn compose_panel(cov: &[u32], w: u32, h: u32, radius: f32, st: &PanelStyle) -> Vec<u32> {
    let (fw, fh) = (w as f32, h as f32);
    let mut out = Vec::with_capacity(cov.len());
    for y in 0..h {
        for x in 0..w {
            let c = cov[(y * w + x) as usize];
            let a = ((c & 0xFF).max((c >> 8) & 0xFF).max((c >> 16) & 0xFF)) as f32 / 255.0;
            // rounded-rect signed distance at the pixel center → 1px antialiased edge
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            let qx = (px - fw / 2.0).abs() - (fw / 2.0 - radius);
            let qy = (py - fh / 2.0).abs() - (fh / 2.0 - radius);
            let d = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt() + qx.max(qy).min(0.0) - radius;
            let m = (0.5 - d).clamp(0.0, 1.0);
            let ba = st.bg_alpha * m * (1.0 - a);
            let out_a = a * m + ba;
            let ch = |i: usize| ((st.fg[i] * a * m + st.bg[i] * ba) * 255.0 + 0.5).min(255.0) as u32;
            out.push(ch(2) | ch(1) << 8 | ch(0) << 16 | ((out_a * 255.0 + 0.5).min(255.0) as u32) << 24);
        }
    }
    out
}
