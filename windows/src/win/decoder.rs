//! Media Foundation decoder MFT (HEVC via the HEVC Video Extension, H.264 built in),
//! hardware-accelerated through D3D11 (MFT_MESSAGE_SET_D3D_MANAGER), low-latency mode.
//! Decoded frames are copied into our own shader-readable texture (`FrameTex`).

use super::d3d::Gpu;
use crate::protocol::{Codec, VideoConfig};
use std::ffi::c_void;
use std::mem::ManuallyDrop;
use windows::core::{Interface, Result, GUID, PWSTR};
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::CoTaskMemFree;

/// Decoder output pixel formats we can render.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutFormat {
    Nv12,
    P010,
    Ayuv,
    Y410,
    Y416,
}

impl OutFormat {
    pub fn from_subtype(g: &GUID) -> Option<OutFormat> {
        Some(match *g {
            x if x == MFVideoFormat_NV12 => OutFormat::Nv12,
            x if x == MFVideoFormat_P010 => OutFormat::P010,
            x if x == MFVideoFormat_AYUV => OutFormat::Ayuv,
            x if x == MFVideoFormat_Y410 => OutFormat::Y410,
            x if x == MFVideoFormat_Y416 => OutFormat::Y416,
            _ => return None,
        })
    }
    pub fn dxgi(self) -> DXGI_FORMAT {
        match self {
            OutFormat::Nv12 => DXGI_FORMAT_NV12,
            OutFormat::P010 => DXGI_FORMAT_P010,
            OutFormat::Ayuv => DXGI_FORMAT_AYUV,
            OutFormat::Y410 => DXGI_FORMAT_Y410,
            OutFormat::Y416 => DXGI_FORMAT_Y416,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            OutFormat::Nv12 => "NV12",
            OutFormat::P010 => "P010",
            OutFormat::Ayuv => "AYUV",
            OutFormat::Y410 => "Y410",
            OutFormat::Y416 => "Y416",
        }
    }
    pub fn is_444(self) -> bool {
        matches!(self, OutFormat::Ayuv | OutFormat::Y410 | OutFormat::Y416)
    }
    /// Pixel shader layout selector: 0 = two-plane (Y + interleaved UV), 1 = AYUV (V,U,Y,A), 2 = Y410/Y416 (U,Y,V,A).
    pub fn shader_mode(self) -> u32 {
        match self {
            OutFormat::Nv12 | OutFormat::P010 => 0,
            OutFormat::Ayuv => 1,
            OutFormat::Y410 | OutFormat::Y416 => 2,
        }
    }
    /// SRV formats per plane.
    fn srv_formats(self) -> (DXGI_FORMAT, Option<DXGI_FORMAT>) {
        match self {
            OutFormat::Nv12 => (DXGI_FORMAT_R8_UNORM, Some(DXGI_FORMAT_R8G8_UNORM)),
            OutFormat::P010 => (DXGI_FORMAT_R16_UNORM, Some(DXGI_FORMAT_R16G16_UNORM)),
            OutFormat::Ayuv => (DXGI_FORMAT_R8G8B8A8_UNORM, None),
            OutFormat::Y410 => (DXGI_FORMAT_R10G10B10A2_UNORM, None),
            OutFormat::Y416 => (DXGI_FORMAT_R16G16B16A16_UNORM, None),
        }
    }
    /// Bytes per row for the luma/packed plane (per pixel width).
    fn bytes_per_px(self) -> u32 {
        match self {
            OutFormat::Nv12 => 1,
            OutFormat::P010 => 2,
            OutFormat::Ayuv | OutFormat::Y410 => 4,
            OutFormat::Y416 => 8,
        }
    }
    fn planar(self) -> bool {
        matches!(self, OutFormat::Nv12 | OutFormat::P010)
    }
}

pub fn codec_subtype(c: Codec) -> GUID {
    match c {
        Codec::H264 => MFVideoFormat_H264,
        _ => MFVideoFormat_HEVC,
    }
}

/// A decoded frame in our own texture with shader resource views.
pub struct FrameTex {
    pub tex: ID3D11Texture2D,
    pub fmt: OutFormat,
    pub w: u32,
    pub h: u32,
    pub srv0: ID3D11ShaderResourceView,
    pub srv1: Option<ID3D11ShaderResourceView>,
}

#[derive(Clone, Debug)]
pub struct MftInfo {
    pub name: String,
    pub clsid: GUID,
    pub flags: u32,
    pub hardware_url: Option<String>,
}

impl MftInfo {
    pub fn is_hardware(&self) -> bool {
        self.flags & MFT_ENUM_FLAG_HARDWARE.0 as u32 != 0 || self.hardware_url.is_some()
    }
    pub fn is_async(&self) -> bool {
        self.flags & MFT_ENUM_FLAG_ASYNCMFT.0 as u32 != 0
    }
}

unsafe fn get_string(a: &IMFAttributes, key: &GUID) -> Option<String> {
    let mut p = PWSTR::null();
    let mut len = 0u32;
    if a.GetAllocatedString(key, &mut p, &mut len).is_ok() && !p.is_null() {
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const c_void));
        s
    } else {
        None
    }
}

/// Enumerate video decoder MFTs accepting `subtype`.
pub fn enum_decoders(subtype: &GUID, flags: MFT_ENUM_FLAG) -> Result<Vec<(MftInfo, IMFActivate)>> {
    super::d3d::mf_startup()?;
    unsafe {
        let input = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: *subtype };
        let mut pp: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n = 0u32;
        MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, flags, Some(&input), None, &mut pp, &mut n)?;
        let mut out = Vec::new();
        if !pp.is_null() {
            for slot in std::slice::from_raw_parts_mut(pp, n as usize) {
                if let Some(a) = slot.take() {
                    let attrs: IMFAttributes = a.cast()?;
                    let info = MftInfo {
                        name: get_string(&attrs, &MFT_FRIENDLY_NAME_Attribute).unwrap_or_else(|| "?".into()),
                        clsid: attrs.GetGUID(&MFT_TRANSFORM_CLSID_Attribute).unwrap_or_default(),
                        flags: attrs.GetUINT32(&MF_TRANSFORM_FLAGS_Attribute).unwrap_or(0),
                        hardware_url: get_string(&attrs, &MFT_ENUM_HARDWARE_URL_Attribute),
                    };
                    out.push((info, a));
                }
            }
            CoTaskMemFree(Some(pp as *const c_void));
        }
        Ok(out)
    }
}

pub fn input_type(codec: Codec, w: u32, h: u32, h265_profile: Option<u32>) -> Result<IMFMediaType> {
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, &codec_subtype(codec))?;
        t.SetUINT64(&MF_MT_FRAME_SIZE, ((w as u64) << 32) | h as u64)?;
        t.SetUINT64(&MF_MT_FRAME_RATE, (60u64 << 32) | 1)?;
        t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        if let Some(p) = h265_profile {
            t.SetUINT32(&MF_MT_MPEG2_PROFILE, p)?;
        }
        Ok(t)
    }
}

pub struct Decoder {
    gpu_device: ID3D11Device,
    gpu_context: ID3D11DeviceContext,
    mft: IMFTransform,
    pub info: MftInfo,
    /// True when the D3D11 device manager was accepted (DXVA hardware decode).
    pub d3d: bool,
    pub codec: Codec,
    pub out_fmt: Option<OutFormat>,
    /// Decoder output frame size (may be padded, e.g. 1088).
    pub out_size: (u32, u32),
    display: (u32, u32),
    prefer_444: bool,
    sample_time: i64,
    pub frame: Option<FrameTex>,
    staging: Option<ID3D11Texture2D>,
    /// True if the last output came from a D3D11 texture (vs system memory).
    pub last_output_gpu: bool,
    pub stream_changes: u32,
}

impl Decoder {
    /// Create a decoder for `cfg` using the first suitable synchronous MFT.
    pub fn new(gpu: &Gpu, cfg: &VideoConfig) -> Result<Decoder> {
        Self::new_with(gpu, cfg.codec, cfg.width as u32, cfg.height as u32, cfg.chroma == 1, None, true)
    }

    pub fn new_with(
        gpu: &Gpu,
        codec: Codec,
        w: u32,
        h: u32,
        prefer_444: bool,
        h265_profile: Option<u32>,
        use_d3d: bool,
    ) -> Result<Decoder> {
        let cands = enum_decoders(&codec_subtype(codec), MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER)?;
        let mut last_err = windows::core::Error::from_hresult(windows::Win32::Foundation::E_FAIL);
        for (info, act) in cands {
            match Self::try_create(gpu, &info, &act, codec, w, h, prefer_444, h265_profile, use_d3d) {
                Ok(d) => return Ok(d),
                Err(e) => last_err = e,
            }
        }
        Err(last_err)
    }

    #[allow(clippy::too_many_arguments)]
    fn try_create(
        gpu: &Gpu,
        info: &MftInfo,
        act: &IMFActivate,
        codec: Codec,
        w: u32,
        h: u32,
        prefer_444: bool,
        h265_profile: Option<u32>,
        use_d3d: bool,
    ) -> Result<Decoder> {
        unsafe {
            let mft: IMFTransform = act.ActivateObject()?;
            let mut d3d = false;
            if let Ok(attrs) = mft.GetAttributes() {
                let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
                let aware = attrs.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) != 0;
                if aware && use_d3d {
                    d3d = mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, gpu.manager.as_raw() as usize).is_ok();
                }
            }
            mft.SetInputType(0, &input_type(codec, w, h, h265_profile)?, 0)?;
            let mut dec = Decoder {
                gpu_device: gpu.device.clone(),
                gpu_context: gpu.context.clone(),
                mft,
                info: info.clone(),
                d3d,
                codec,
                out_fmt: None,
                out_size: (w, h),
                display: (w & !1, h & !1),
                prefer_444,
                sample_time: 0,
                frame: None,
                staging: None,
                last_output_gpu: false,
                stream_changes: 0,
            };
            dec.negotiate_output()?;
            dec.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            dec.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            Ok(dec)
        }
    }

    /// All output subtypes currently offered (GUIDs), for diagnostics.
    pub fn available_outputs(&self) -> Vec<GUID> {
        let mut v = Vec::new();
        unsafe {
            for i in 0..64 {
                match self.mft.GetOutputAvailableType(0, i) {
                    Ok(t) => v.push(t.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default()),
                    Err(_) => break,
                }
            }
        }
        v
    }

    fn negotiate_output(&mut self) -> Result<()> {
        unsafe {
            let pref: &[OutFormat] = if self.prefer_444 {
                &[OutFormat::Ayuv, OutFormat::Y410, OutFormat::Y416, OutFormat::Nv12, OutFormat::P010]
            } else {
                &[OutFormat::Nv12, OutFormat::P010, OutFormat::Ayuv, OutFormat::Y410, OutFormat::Y416]
            };
            let mut offered: Vec<(OutFormat, IMFMediaType)> = Vec::new();
            for i in 0..64 {
                match self.mft.GetOutputAvailableType(0, i) {
                    Ok(t) => {
                        if let Some(f) = OutFormat::from_subtype(&t.GetGUID(&MF_MT_SUBTYPE)?) {
                            offered.push((f, t));
                        }
                    }
                    Err(_) => break,
                }
            }
            // A 4:4:4 stream must use a 4:4:4 format if one is offered; otherwise follow preference.
            let pick = pref.iter().find_map(|p| offered.iter().find(|(f, _)| f == p));
            let Some((fmt, t)) = pick else {
                return Err(windows::core::Error::new(
                    MF_E_INVALIDMEDIATYPE,
                    format!("decoder offers no supported output format ({} types)", self.available_outputs().len()),
                ));
            };
            self.mft.SetOutputType(0, t, 0)?;
            self.out_fmt = Some(*fmt);
            if let Ok(sz) = t.GetUINT64(&MF_MT_FRAME_SIZE) {
                self.out_size = ((sz >> 32) as u32, sz as u32);
            }
            Ok(())
        }
    }

    /// Feed one Annex-B access unit; returns how many frames were produced (copied to `self.frame`).
    pub fn decode(&mut self, data: &[u8], keyframe: bool) -> Result<u32> {
        let sample = unsafe { self.make_sample(data, keyframe)? };
        let mut produced = 0;
        unsafe {
            let mut tries = 0;
            loop {
                match self.mft.ProcessInput(0, &sample, 0) {
                    Ok(()) => break,
                    Err(e) if e.code() == MF_E_NOTACCEPTING && tries < 4 => {
                        tries += 1;
                        produced += self.drain_outputs()?;
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        produced += unsafe { self.drain_outputs()? };
        Ok(produced)
    }

    /// Signal end of input and collect any buffered frames.
    pub fn drain(&mut self) -> Result<u32> {
        unsafe {
            self.mft.ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0)?;
            self.drain_outputs()
        }
    }

    pub fn device(&self) -> &ID3D11Device {
        &self.gpu_device
    }

    pub fn context(&self) -> &ID3D11DeviceContext {
        &self.gpu_context
    }

    unsafe fn make_sample(&mut self, data: &[u8], keyframe: bool) -> Result<IMFSample> {
        let buf = MFCreateMemoryBuffer(data.len() as u32)?;
        let mut p: *mut u8 = std::ptr::null_mut();
        buf.Lock(&mut p, None, None)?;
        std::ptr::copy_nonoverlapping(data.as_ptr(), p, data.len());
        buf.Unlock()?;
        buf.SetCurrentLength(data.len() as u32)?;
        let s = MFCreateSample()?;
        s.AddBuffer(&buf)?;
        s.SetSampleTime(self.sample_time)?;
        s.SetSampleDuration(166_667)?;
        if keyframe {
            s.SetUINT32(&MFSampleExtension_CleanPoint, 1)?;
        }
        self.sample_time += 166_667;
        Ok(s)
    }

    unsafe fn drain_outputs(&mut self) -> Result<u32> {
        let mut n = 0;
        for _ in 0..32 {
            let info = self.mft.GetOutputStreamInfo(0)?;
            let provides = info.dwFlags
                & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32
                != 0;
            let own = if provides {
                None
            } else {
                let s = MFCreateSample()?;
                let b = MFCreateMemoryBuffer(info.cbSize.max(1))?;
                s.AddBuffer(&b)?;
                Some(s)
            };
            let mut odb = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: ManuallyDrop::new(own),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            }];
            let mut status = 0u32;
            let r = self.mft.ProcessOutput(0, &mut odb, &mut status);
            let sample = ManuallyDrop::take(&mut odb[0].pSample);
            let _events = ManuallyDrop::take(&mut odb[0].pEvents);
            match r {
                Ok(()) => {
                    if let Some(s) = sample {
                        self.take_output(&s)?;
                        n += 1;
                    }
                }
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(n),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    self.stream_changes += 1;
                    self.negotiate_output()?;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(n)
    }

    fn ensure_frame(&mut self, fmt: OutFormat, w: u32, h: u32) -> Result<()> {
        let ok = matches!(&self.frame, Some(f) if f.fmt == fmt && f.w == w && f.h == h);
        if !ok {
            self.frame = Some(create_frame_tex(&self.gpu_device, fmt, w, h)?);
            self.staging = None;
        }
        Ok(())
    }

    unsafe fn take_output(&mut self, s: &IMFSample) -> Result<()> {
        let fmt = self.out_fmt.unwrap_or(OutFormat::Nv12);
        let buffer = s.GetBufferByIndex(0)?;
        if let Ok(dxgi) = buffer.cast::<IMFDXGIBuffer>() {
            let mut p: *mut c_void = std::ptr::null_mut();
            dxgi.GetResource(&ID3D11Texture2D::IID, &mut p)?;
            let src = ID3D11Texture2D::from_raw(p);
            let idx = dxgi.GetSubresourceIndex()?;
            let mut sd = D3D11_TEXTURE2D_DESC::default();
            src.GetDesc(&mut sd);
            let w = self.display.0.min(sd.Width) & !1;
            let h = self.display.1.min(sd.Height) & !1;
            self.ensure_frame(fmt, w, h)?;
            let dst = &self.frame.as_ref().unwrap().tex;
            let bx = D3D11_BOX { left: 0, top: 0, front: 0, right: w, bottom: h, back: 1 };
            self.gpu_context.CopySubresourceRegion(dst, 0, 0, 0, 0, &src, idx, Some(&bx));
            self.last_output_gpu = true;
        } else {
            self.upload_system_memory(&buffer, fmt)?;
            self.last_output_gpu = false;
        }
        Ok(())
    }

    /// Software-decoder fallback: copy a system-memory frame into our texture via a staging texture.
    unsafe fn upload_system_memory(&mut self, buffer: &IMFMediaBuffer, fmt: OutFormat) -> Result<()> {
        let (ow, oh) = self.out_size;
        let w = self.display.0.min(ow) & !1;
        let h = self.display.1.min(oh) & !1;
        self.ensure_frame(fmt, w, h)?;
        if self.staging.is_none() {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: w,
                Height: h,
                MipLevels: 1,
                ArraySize: 1,
                Format: fmt.dxgi(),
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
                MiscFlags: 0,
            };
            let mut t = None;
            self.gpu_device.CreateTexture2D(&desc, None, Some(&mut t))?;
            self.staging = t;
        }
        let staging = self.staging.as_ref().unwrap();
        // Source layout: prefer IMF2DBuffer pitch; else assume tightly packed at out_size.
        let (src, pitch, locked2d) = if let Ok(b2) = buffer.cast::<IMF2DBuffer>() {
            let mut p: *mut u8 = std::ptr::null_mut();
            let mut pitch = 0i32;
            b2.Lock2D(&mut p, &mut pitch)?;
            (p as *const u8, pitch.unsigned_abs() as usize, Some(b2))
        } else {
            let mut p: *mut u8 = std::ptr::null_mut();
            buffer.Lock(&mut p, None, None)?;
            (p as *const u8, (ow * fmt.bytes_per_px()) as usize, None)
        };
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        let map_r = self.gpu_context.Map(staging, 0, D3D11_MAP_WRITE, 0, Some(&mut m));
        if map_r.is_ok() {
            let dst = m.pData as *mut u8;
            let dp = m.RowPitch as usize;
            let row = (w * fmt.bytes_per_px()) as usize;
            for y in 0..h as usize {
                std::ptr::copy_nonoverlapping(src.add(y * pitch), dst.add(y * dp), row);
            }
            if fmt.planar() {
                let src_uv = src.add(pitch * oh as usize);
                let dst_uv = dst.add(dp * h as usize);
                for y in 0..(h / 2) as usize {
                    std::ptr::copy_nonoverlapping(src_uv.add(y * pitch), dst_uv.add(y * dp), row);
                }
            }
            self.gpu_context.Unmap(staging, 0);
        }
        match locked2d {
            Some(b2) => b2.Unlock2D()?,
            None => buffer.Unlock()?,
        }
        map_r?;
        self.gpu_context.CopyResource(&self.frame.as_ref().unwrap().tex, staging);
        Ok(())
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe {
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, 0);
        }
    }
}

pub fn create_frame_tex(device: &ID3D11Device, fmt: OutFormat, w: u32, h: u32) -> Result<FrameTex> {
    unsafe {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: fmt.dxgi(),
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut tex = None;
        device.CreateTexture2D(&desc, None, Some(&mut tex))?;
        let tex: ID3D11Texture2D = tex.unwrap();
        let (f0, f1) = fmt.srv_formats();
        let srv = |f: DXGI_FORMAT| -> Result<ID3D11ShaderResourceView> {
            let d = D3D11_SHADER_RESOURCE_VIEW_DESC {
                Format: f,
                ViewDimension: D3D_SRV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_SRV { MostDetailedMip: 0, MipLevels: 1 } },
            };
            let mut v = None;
            device.CreateShaderResourceView(&tex, Some(&d), Some(&mut v))?;
            Ok(v.unwrap())
        };
        let srv0 = srv(f0)?;
        let srv1 = match f1 {
            Some(f) => Some(srv(f)?),
            None => None,
        };
        Ok(FrameTex { tex, fmt, w, h, srv0, srv1 })
    }
}
