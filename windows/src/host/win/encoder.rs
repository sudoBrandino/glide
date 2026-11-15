//! Media Foundation video encoder MFT (H.264 always; HEVC when the viewer decodes it and an
//! encoder exists), fed NV12 D3D11 textures.
//!
//! - Hardware MFTs (`MFT_ENUM_FLAG_HARDWARE`, the GPU's encoder) first, preferring the one on
//!   the capture adapter (`MFT_ENUM_ADAPTER_LUID`); they are asynchronous: unlocked with
//!   `MF_TRANSFORM_ASYNC_UNLOCK` and driven by METransformNeedInput / METransformHaveOutput events.
//! - Fallback: the synchronous software MFT (Microsoft's), fed system-memory NV12 read back from
//!   the texture when it isn't D3D11-aware.
//! - `CODECAPI_AVLowLatencyMode`, no B-frames, CBR at the given bitrate, a long GOP (keyframes on
//!   demand with `CODECAPI_AVEncVideoForceKeyFrame`).
//! - Output is Annex-B; keyframes get the parameter sets from `MF_MT_MPEG_SEQUENCE_HEADER` if the
//!   encoder didn't put them in-band (`video::prepare_access_unit`).
//! - One frame in flight: `encode` submits one frame and waits briefly for its output.

use super::capture::Device;
use super::hr;
use crate::host::log;
use crate::host::video::{is_keyframe, prepare_access_unit};
use crate::protocol::Codec;
use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::time::{Duration, Instant};
use windows::core::{Interface, Result, GUID, PWSTR};
use windows::Win32::Foundation::{E_FAIL, LUID};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::Variant::VARIANT;

pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub keyframe: bool,
}

fn subtype(c: Codec) -> GUID {
    if c == Codec::Hevc {
        MFVideoFormat_HEVC
    } else {
        MFVideoFormat_H264
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

struct Candidate {
    name: String,
    hardware: bool,
    /// Some(true) = on the capture adapter, Some(false) = another adapter, None = unknown.
    same_adapter: Option<bool>,
    act: IMFActivate,
}

fn enumerate(codec: Codec, flags: MFT_ENUM_FLAG, hardware: bool, luid: Option<LUID>) -> Vec<Candidate> {
    let mut out = Vec::new();
    unsafe {
        let input = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_NV12 };
        let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: subtype(codec) };
        let mut pp: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n = 0u32;
        if MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, Some(&input), Some(&output), &mut pp, &mut n).is_err() || pp.is_null() {
            return out;
        }
        for slot in std::slice::from_raw_parts_mut(pp, n as usize) {
            if let Some(act) = slot.take() {
                let Ok(attrs) = act.cast::<IMFAttributes>() else { continue };
                let name = get_string(&attrs, &MFT_FRIENDLY_NAME_Attribute).unwrap_or_else(|| "?".into());
                let same_adapter = match (luid, attrs.GetUINT64(&MFT_ENUM_ADAPTER_LUID)) {
                    (Some(l), Ok(v)) => Some(v == (((l.HighPart as u32 as u64) << 32) | l.LowPart as u64)),
                    _ => None,
                };
                out.push(Candidate { name, hardware, same_adapter, act });
            }
        }
        CoTaskMemFree(Some(pp as *const c_void));
    }
    // Encoders on the capture adapter first, unknown next, other adapters last (stable).
    out.sort_by_key(|c| match c.same_adapter {
        Some(true) => 0,
        None => 1,
        Some(false) => 2,
    });
    out
}

/// Whether any encoder (hardware or software) for `codec` is registered.
pub fn available(codec: Codec) -> bool {
    if crate::win::d3d::mf_startup().is_err() {
        return false;
    }
    !enumerate(codec, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, true, None).is_empty()
        || !enumerate(codec, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, false, None).is_empty()
}

pub struct Encoder {
    mft: IMFTransform,
    events: Option<IMFMediaEventGenerator>,
    codec_api: Option<ICodecAPI>,
    pub codec: Codec,
    pub name: String,
    pub hardware: bool,
    /// Takes D3D11 textures (else system-memory NV12).
    d3d: bool,
    w: u32,
    h: u32,
    fps: u32,
    /// Async MFTs: METransformNeedInput events not yet answered.
    need_input: u32,
    sample_time: i64,
    seq_header: Option<Vec<u8>>,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    staging: Option<ID3D11Texture2D>,
    pending: Vec<EncodedFrame>,
}

// The MFT and D3D objects are used from the session's video thread only.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(dev: &Device, codec: Codec, w: u32, h: u32, fps: u32, bitrate_kbps: u32, luid: Option<LUID>) -> Result<Encoder> {
        crate::win::d3d::mf_startup()?;
        let mut cands = enumerate(codec, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, true, luid);
        cands.extend(enumerate(codec, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, false, None));
        let mut last = windows::core::Error::new(E_FAIL, format!("no {} encoder found", codec.name()));
        for c in cands {
            match Encoder::try_create(dev, &c, codec, w, h, fps, bitrate_kbps) {
                Ok(e) => {
                    log(&format!(
                        "encoder: {} ({}, {}) {} {}x{} @{} fps, {} kbps",
                        e.name,
                        if e.hardware { "hardware" } else { "software" },
                        if e.d3d { "D3D11" } else { "system memory" },
                        codec.name(),
                        w,
                        h,
                        fps,
                        bitrate_kbps
                    ));
                    return Ok(e);
                }
                Err(e) => {
                    log(&format!("encoder: {} failed: {}", c.name, hr(&e)));
                    last = e;
                }
            }
        }
        Err(last)
    }

    fn try_create(dev: &Device, c: &Candidate, codec: Codec, w: u32, h: u32, fps: u32, bitrate_kbps: u32) -> Result<Encoder> {
        unsafe {
            let mft: IMFTransform = c.act.ActivateObject()?;
            let attrs = mft.GetAttributes().ok();
            let is_async = attrs.as_ref().is_some_and(|a| a.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) != 0);
            if let Some(a) = &attrs {
                if is_async {
                    a.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
                }
                let _ = a.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            let aware = attrs.as_ref().is_some_and(|a| a.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) != 0);
            let mut d3d = false;
            if aware || c.hardware {
                match mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, dev.manager.as_raw() as usize) {
                    Ok(()) => d3d = true,
                    Err(e) if c.hardware => return Err(e),
                    Err(_) => {}
                }
            }
            let codec_api = mft.cast::<ICodecAPI>().ok();
            if let Some(api) = &codec_api {
                let set = |g: &GUID, v: VARIANT, what: &str| {
                    if let Err(e) = api.SetValue(g, &v) {
                        log(&format!("encoder: {}: {what} not supported ({})", c.name, hr(&e)));
                    }
                };
                set(&CODECAPI_AVLowLatencyMode, VARIANT::from(true), "low-latency mode");
                set(&CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32), "CBR");
                set(&CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bitrate_kbps.saturating_mul(1000)), "bitrate");
                set(&CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32), "B-frame count 0");
                set(&CODECAPI_AVEncMPVGOPSize, VARIANT::from(fps.max(1) * 120), "GOP size");
            }
            // Output type first (encoders), then NV12 input.
            let out = MFCreateMediaType()?;
            out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            out.SetGUID(&MF_MT_SUBTYPE, &subtype(codec))?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, bitrate_kbps.saturating_mul(1000))?;
            out.SetUINT64(&MF_MT_FRAME_SIZE, ((w as u64) << 32) | h as u64)?;
            out.SetUINT64(&MF_MT_FRAME_RATE, ((fps as u64) << 32) | 1)?;
            out.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
            out.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            out.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
            out.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32)?;
            let profile = if codec == Codec::Hevc { eAVEncH265VProfile_Main_420_8.0 } else { eAVEncH264VProfile_High.0 };
            out.SetUINT32(&MF_MT_MPEG2_PROFILE, profile as u32)?;
            mft.SetOutputType(0, &out, 0)?;
            let mut input = None;
            for i in 0..64 {
                match mft.GetInputAvailableType(0, i) {
                    Ok(t) if t.GetGUID(&MF_MT_SUBTYPE).ok() == Some(MFVideoFormat_NV12) => {
                        input = Some(t);
                        break;
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            let input = match input {
                Some(t) => t,
                None => {
                    let t = MFCreateMediaType()?;
                    t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
                    t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
                    t
                }
            };
            input.SetUINT64(&MF_MT_FRAME_SIZE, ((w as u64) << 32) | h as u64)?;
            input.SetUINT64(&MF_MT_FRAME_RATE, ((fps as u64) << 32) | 1)?;
            input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
            input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            let _ = input.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32);
            let _ = input.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32);
            mft.SetInputType(0, &input, 0)?;
            let events = if is_async { Some(mft.cast::<IMFMediaEventGenerator>()?) } else { None };
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            let mut e = Encoder {
                mft,
                events,
                codec_api,
                codec,
                name: c.name.clone(),
                hardware: c.hardware,
                d3d,
                w,
                h,
                fps: fps.max(1),
                need_input: 0,
                sample_time: 0,
                seq_header: None,
                device: dev.device.clone(),
                context: dev.context.clone(),
                staging: None,
                pending: Vec::new(),
            };
            e.refresh_sequence_header();
            Ok(e)
        }
    }

    fn refresh_sequence_header(&mut self) {
        unsafe {
            if let Ok(t) = self.mft.GetOutputCurrentType(0) {
                if let Ok(n) = t.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) {
                    let mut b = vec![0u8; n as usize];
                    if n > 0 && t.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut b, None).is_ok() {
                        self.seq_header = Some(b);
                    }
                }
            }
        }
    }

    unsafe fn make_sample(&mut self, tex: &ID3D11Texture2D, time_us: u64) -> Result<IMFSample> {
        let buf = if self.d3d {
            let b = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, tex, 0, false)?;
            if let Ok(b2) = b.cast::<IMF2DBuffer>() {
                if let Ok(n) = b2.GetContiguousLength() {
                    let _ = b.SetCurrentLength(n);
                }
            }
            b
        } else {
            self.read_back(tex)?
        };
        let s = MFCreateSample()?;
        s.AddBuffer(&buf)?;
        let t = (time_us as i64) * 10;
        self.sample_time = t.max(self.sample_time + 1);
        s.SetSampleTime(self.sample_time)?;
        s.SetSampleDuration(10_000_000 / self.fps as i64)?;
        Ok(s)
    }

    /// Software encoder without D3D11: NV12 texture → tightly packed system-memory NV12.
    unsafe fn read_back(&mut self, tex: &ID3D11Texture2D) -> Result<IMFMediaBuffer> {
        let (w, h) = (self.w as usize, self.h as usize);
        if self.staging.is_none() {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: self.w,
                Height: self.h,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_NV12,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut t = None;
            self.device.CreateTexture2D(&desc, None, Some(&mut t))?;
            self.staging = t;
        }
        let staging = self.staging.as_ref().unwrap();
        self.context.CopyResource(staging, tex);
        let size = w * h * 3 / 2;
        let buf = MFCreateMemoryBuffer(size as u32)?;
        let mut dst: *mut u8 = std::ptr::null_mut();
        buf.Lock(&mut dst, None, None)?;
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        let r = self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut m));
        if r.is_ok() {
            let src = m.pData as *const u8;
            let pitch = m.RowPitch as usize;
            for y in 0..h {
                std::ptr::copy_nonoverlapping(src.add(y * pitch), dst.add(y * w), w);
            }
            let (suv, duv) = (src.add(pitch * h), dst.add(w * h));
            for y in 0..h / 2 {
                std::ptr::copy_nonoverlapping(suv.add(y * pitch), duv.add(y * w), w);
            }
            self.context.Unmap(staging, 0);
        }
        buf.Unlock()?;
        r?;
        buf.SetCurrentLength(size as u32)?;
        Ok(buf)
    }

    /// Encodes one frame (keyframe = force an IDR). Returns the access units that came out (the
    /// one for this frame, normally; possibly none yet if the encoder is slow, then it comes with
    /// the next call).
    pub fn encode(&mut self, tex: &ID3D11Texture2D, keyframe: bool, time_us: u64) -> Result<Vec<EncodedFrame>> {
        unsafe {
            if keyframe {
                if let Some(api) = &self.codec_api {
                    let _ = api.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &VARIANT::from(1u32));
                }
            }
            let sample = self.make_sample(tex, time_us)?;
            if self.events.is_some() {
                // Wait for the encoder to ask for input (one frame in flight).
                let until = Instant::now() + Duration::from_millis(500);
                while self.need_input == 0 {
                    self.pump()?;
                    if self.need_input > 0 {
                        break;
                    }
                    if Instant::now() >= until {
                        return Err(windows::core::Error::new(E_FAIL, "encoder stopped asking for input"));
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
                self.mft.ProcessInput(0, &sample, 0)?;
                self.need_input -= 1;
                let until = Instant::now() + Duration::from_millis(250);
                while self.pending.is_empty() && Instant::now() < until {
                    self.pump()?;
                    if self.pending.is_empty() {
                        std::thread::sleep(Duration::from_micros(500));
                    }
                }
            } else {
                match self.mft.ProcessInput(0, &sample, 0) {
                    Ok(()) => {}
                    Err(e) if e.code() == MF_E_NOTACCEPTING => {
                        while self.output_once()? {}
                        self.mft.ProcessInput(0, &sample, 0)?;
                    }
                    Err(e) => return Err(e),
                }
                while self.output_once()? {}
            }
            Ok(std::mem::take(&mut self.pending))
        }
    }

    /// Async MFTs: handle every queued event without waiting.
    unsafe fn pump(&mut self) -> Result<()> {
        loop {
            let Some(ev) = self.events.as_ref() else { return Ok(()) };
            let e = match ev.GetEvent(MF_EVENT_FLAG_NO_WAIT) {
                Ok(e) => e,
                Err(e) if e.code() == MF_E_NO_EVENTS_AVAILABLE => return Ok(()),
                Err(e) => return Err(e),
            };
            let t = e.GetType()?;
            if t == METransformNeedInput.0 as u32 {
                self.need_input += 1;
            } else if t == METransformHaveOutput.0 as u32 {
                self.output_once()?;
            }
        }
    }

    /// One ProcessOutput call. Ok(true) = got (or handled) output, try again; Ok(false) = needs input.
    unsafe fn output_once(&mut self) -> Result<bool> {
        let info = self.mft.GetOutputStreamInfo(0)?;
        let provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32 != 0;
        let own = if provides {
            None
        } else {
            let s = MFCreateSample()?;
            let size = info.cbSize.max(self.w * self.h * 2).max(1 << 20);
            s.AddBuffer(&MFCreateMemoryBuffer(size)?)?;
            Some(s)
        };
        let mut odb = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(own), dwStatus: 0, pEvents: ManuallyDrop::new(None) }];
        let mut status = 0u32;
        let r = self.mft.ProcessOutput(0, &mut odb, &mut status);
        let sample = ManuallyDrop::take(&mut odb[0].pSample);
        let _events = ManuallyDrop::take(&mut odb[0].pEvents);
        match r {
            Ok(()) => {}
            Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(false),
            Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                log(&format!("encoder: {}: output format changed", self.name));
                let t = self.mft.GetOutputAvailableType(0, 0)?;
                self.mft.SetOutputType(0, &t, 0)?;
                self.refresh_sequence_header();
                return Ok(true);
            }
            Err(e) => return Err(e),
        }
        let Some(sample) = sample else { return Ok(true) };
        let buf = sample.ConvertToContiguousBuffer()?;
        let mut p: *mut u8 = std::ptr::null_mut();
        let mut len = 0u32;
        buf.Lock(&mut p, None, Some(&mut len))?;
        let data = std::slice::from_raw_parts(p, len as usize).to_vec();
        buf.Unlock()?;
        if data.is_empty() {
            return Ok(true);
        }
        let key = sample.GetUINT32(&MFSampleExtension_CleanPoint).unwrap_or(0) != 0 || is_keyframe(&data, self.codec);
        if key && self.seq_header.is_none() {
            self.refresh_sequence_header();
        }
        let data = prepare_access_unit(&data, self.codec, key, self.seq_header.as_deref());
        self.pending.push(EncodedFrame { data, keyframe: key });
        Ok(true)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe {
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, 0);
            if let Ok(s) = self.mft.cast::<IMFShutdown>() {
                let _ = s.Shutdown();
            }
        }
    }
}
