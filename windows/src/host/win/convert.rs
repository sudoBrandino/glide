//! GPU scaling + BGRA → NV12 (BT.709, limited range) with the D3D11 video processor, into a small
//! ring of NV12 textures the encoder reads (so a frame still being encoded is never overwritten).

use windows::core::{Interface, Result};
use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;

const RING: usize = 3;

pub struct Converter {
    vdev: ID3D11VideoDevice,
    vctx: ID3D11VideoContext,
    venum: ID3D11VideoProcessorEnumerator,
    vp: ID3D11VideoProcessor,
    outputs: Vec<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
    next: usize,
    /// Input view for the current source texture (re-created when the texture changes).
    input: Option<(usize, ID3D11VideoProcessorInputView)>,
    pub in_w: u32,
    pub in_h: u32,
    pub out_w: u32,
    pub out_h: u32,
}

impl Converter {
    /// `in_w` x `in_h`: the desktop texture; `out_w` x `out_h`: the encoded size (even).
    /// `rotation`: the output's rotation (the desktop texture is in panel orientation).
    pub fn new(
        device: &ID3D11Device,
        context: &ID3D11DeviceContext,
        in_w: u32,
        in_h: u32,
        out_w: u32,
        out_h: u32,
        rotation: DXGI_MODE_ROTATION,
    ) -> Result<Converter> {
        unsafe {
            let vdev: ID3D11VideoDevice = device.cast()?;
            let vctx: ID3D11VideoContext = context.cast()?;
            let rate = DXGI_RATIONAL { Numerator: 60, Denominator: 1 };
            let cd = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: rate,
                InputWidth: in_w,
                InputHeight: in_h,
                OutputFrameRate: rate,
                OutputWidth: out_w,
                OutputHeight: out_h,
                Usage: D3D11_VIDEO_USAGE_OPTIMAL_SPEED,
            };
            let venum = vdev.CreateVideoProcessorEnumerator(&cd)?;
            let fmt_ok = |f: DXGI_FORMAT, flag: u32| venum.CheckVideoProcessorFormat(f).map(|s| s & flag != 0).unwrap_or(false);
            if !fmt_ok(DXGI_FORMAT_NV12, D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT.0 as u32) {
                return Err(windows::core::Error::new(windows::Win32::Foundation::E_NOTIMPL, "video processor can't output NV12"));
            }
            let vp = vdev.CreateVideoProcessor(&venum, 0)?;
            let mut outputs = Vec::with_capacity(RING);
            for _ in 0..RING {
                let desc = D3D11_TEXTURE2D_DESC {
                    Width: out_w,
                    Height: out_h,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_NV12,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_DEFAULT,
                    // Shader resource too: some encoder MFTs read their input through a view.
                    BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                    CPUAccessFlags: 0,
                    MiscFlags: 0,
                };
                let mut t = None;
                device.CreateTexture2D(&desc, None, Some(&mut t))?;
                let t: ID3D11Texture2D = t.unwrap();
                let od = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                    ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                    Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
                };
                let mut v = None;
                vdev.CreateVideoProcessorOutputView(&t, &venum, &od, Some(&mut v))?;
                outputs.push((t, v.unwrap()));
            }
            // Color: full-range sRGB in, BT.709 limited-range YCbCr out (VideoConfig color 0).
            if let Ok(v1) = vctx.cast::<ID3D11VideoContext1>() {
                v1.VideoProcessorSetStreamColorSpace1(&vp, 0, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
                v1.VideoProcessorSetOutputColorSpace1(&vp, DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709);
            } else {
                // D3D11_VIDEO_PROCESSOR_COLOR_SPACE bits: Usage:1 RGB_Range:1 YCbCr_Matrix:1 xvYCC:1 Nominal_Range:2
                let input = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: 0 }; // RGB 0-255
                let output = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: (1 << 2) | (1 << 4) }; // BT.709, 16-235
                vctx.VideoProcessorSetStreamColorSpace(&vp, 0, &input);
                vctx.VideoProcessorSetOutputColorSpace(&vp, &output);
            }
            vctx.VideoProcessorSetStreamFrameFormat(&vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            vctx.VideoProcessorSetStreamAutoProcessingMode(&vp, 0, false);
            let src = RECT { left: 0, top: 0, right: in_w as i32, bottom: in_h as i32 };
            let dst = RECT { left: 0, top: 0, right: out_w as i32, bottom: out_h as i32 };
            vctx.VideoProcessorSetStreamSourceRect(&vp, 0, true, Some(&src));
            vctx.VideoProcessorSetStreamDestRect(&vp, 0, true, Some(&dst));
            vctx.VideoProcessorSetOutputTargetRect(&vp, true, Some(&dst));
            // The desktop texture is in panel orientation: rotate it back (untested on real
            // rotated monitors; DXGI's rotation is the one applied for scan-out).
            let rot = match rotation {
                DXGI_MODE_ROTATION_ROTATE90 => Some(D3D11_VIDEO_PROCESSOR_ROTATION_270),
                DXGI_MODE_ROTATION_ROTATE180 => Some(D3D11_VIDEO_PROCESSOR_ROTATION_180),
                DXGI_MODE_ROTATION_ROTATE270 => Some(D3D11_VIDEO_PROCESSOR_ROTATION_90),
                _ => None,
            };
            if let Some(r) = rot {
                vctx.VideoProcessorSetStreamRotation(&vp, 0, true, r);
            }
            Ok(Converter { vdev, vctx, venum, vp, outputs, next: 0, input: None, in_w, in_h, out_w, out_h })
        }
    }

    /// Scales + converts `src` into the next NV12 texture of the ring and returns it.
    pub fn convert(&mut self, src: &ID3D11Texture2D) -> Result<ID3D11Texture2D> {
        unsafe {
            let key = src.as_raw() as usize;
            if self.input.as_ref().map(|(k, _)| *k) != Some(key) {
                let id = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                    FourCC: 0,
                    ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                    Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
                };
                let mut v = None;
                self.vdev.CreateVideoProcessorInputView(src, &self.venum, &id, Some(&mut v))?;
                self.input = Some((key, v.unwrap()));
            }
            let view = self.input.as_ref().map(|(_, v)| v.clone());
            let (tex, out_view) = self.outputs[self.next].clone();
            self.next = (self.next + 1) % self.outputs.len();
            let stream = D3D11_VIDEO_PROCESSOR_STREAM { Enable: true.into(), pInputSurface: std::mem::ManuallyDrop::new(view), ..Default::default() };
            let streams = [stream];
            let r = self.vctx.VideoProcessorBlt(&self.vp, &out_view, 0, &streams);
            let [mut stream] = streams;
            std::mem::ManuallyDrop::drop(&mut stream.pInputSurface);
            r?;
            Ok(tex)
        }
    }
}
