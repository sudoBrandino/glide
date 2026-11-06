//! `--probe`: enumerate decoder MFTs and D3D11 decoder profiles, and actually decode
//! small embedded clips (HEVC Main/Main10/RExt 4:4:4 8+10 bit/4:2:2 10, H.264) to
//! determine whether HEVC 4:4:4 ("sharp" mode) works on this machine.

use super::d3d::Gpu;
use super::decoder::{codec_subtype, enum_decoders, Decoder, FrameTex, OutFormat};
use crate::annexb::{hevc_sps_info, split_access_units};
use crate::protocol::Codec;
use crate::util::json_str;
use std::sync::OnceLock;
use windows::core::{Interface, GUID};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Media::MediaFoundation::*;

pub struct Clip {
    pub name: &'static str,
    pub codec: Codec,
    pub is_444: bool,
    pub data: &'static [u8],
}

pub const CLIPS: &[Clip] = &[
    Clip { name: "hevc_main_420_8", codec: Codec::Hevc, is_444: false, data: include_bytes!("../../assets/hevc_main_420_8.h265") },
    Clip { name: "hevc_main10_420_10", codec: Codec::Hevc, is_444: false, data: include_bytes!("../../assets/hevc_main10_420_10.h265") },
    Clip { name: "hevc_rext_444_8", codec: Codec::Hevc, is_444: true, data: include_bytes!("../../assets/hevc_rext_444_8.h265") },
    Clip { name: "hevc_rext_444_10", codec: Codec::Hevc, is_444: true, data: include_bytes!("../../assets/hevc_rext_444_10.h265") },
    Clip { name: "hevc_rext_422_10", codec: Codec::Hevc, is_444: false, data: include_bytes!("../../assets/hevc_rext_422_10.h265") },
    Clip { name: "h264_420_8", codec: Codec::H264, is_444: false, data: include_bytes!("../../assets/h264_high_420_8.h264") },
];

fn g(u: u128) -> GUID {
    GUID::from_u128(u)
}

/// Known DXVA / D3D11 decoder profile GUIDs.
fn profile_name(p: &GUID) -> &'static str {
    let table: &[(u128, &str)] = &[
        (0x5b11d51b_2f4c_4452_bcc3_09f2a1160cc0, "HEVC_VLD_Main"),
        (0x107af0e0_ef1a_4d19_aba8_67a163073d13, "HEVC_VLD_Main10"),
        (0x1a72925f_0c2c_4f15_96fb_b17d1473603f, "HEVC_VLD_Main12"),
        (0x0bac4fe5_1532_4429_a854_f84de04953db, "HEVC_VLD_Main10_422"),
        (0x55bcac81_f311_4093_a7d0_1cbc0b849bee, "HEVC_VLD_Main12_422"),
        (0x4008018f_f537_4b36_98cf_61af8a2c1a33, "HEVC_VLD_Main_444"),
        (0x9cc55490_e37c_4932_8684_4920f9f6409c, "HEVC_VLD_Main10_Ext"),
        (0x0dabeffa_4458_4602_bc03_0795659d617c, "HEVC_VLD_Main10_444"),
        (0x9798634d_fe9d_48e5_b4da_dbec45b3df01, "HEVC_VLD_Main12_444"),
        (0xa4fbdbb0_a113_482b_a232_635cc0697f6d, "HEVC_VLD_Main16"),
        (0x1b81be68_a0c7_11d3_b984_00c04f2e73c5, "H264_VLD_NoFGT"),
        (0x1b81be69_a0c7_11d3_b984_00c04f2e73c5, "H264_VLD_FGT"),
        (0x1b81be67_a0c7_11d3_b984_00c04f2e73c5, "H264_IDCT_FGT"),
        (0xd5f04ff9_3418_45d8_9561_32a76aae2ddd, "H264_VLD_WithFMOASO_NoFGT"),
        (0xd79be8da_0cf1_4c81_b82a_69a4e236f43d, "H264_VLD_Stereo_Progressive_NoFGT"),
        (0xf9aaccbb_c2b6_4cfc_8779_5707b1760552, "H264_VLD_Stereo_NoFGT"),
        (0x705b9d82_76cf_49d6_b7e6_ac8872db013c, "H264_VLD_Multiview_NoFGT"),
        (0xb8be4ccb_cf53_46ba_8d59_d6b8a6da5d2a, "AV1_VLD_Profile0"),
        (0x6936ff0f_45b1_4163_9cc1_646ef6946108, "AV1_VLD_Profile1"),
        (0x0c5f2aa1_e541_4089_bb7b_98110a19d7c8, "AV1_VLD_Profile2"),
        (0x17127009_a00f_4ce1_994e_bf4081f6f3f0, "AV1_VLD_12bit_Profile2"),
        (0x2d80bed6_9cac_4835_9e91_327bbc4f9ee8, "AV1_VLD_12bit_Profile2_420"),
        (0x463707f8_a1d0_4585_876d_83aa6d60b89e, "VP9_VLD_Profile0"),
        (0xa4c749ef_6ecf_48aa_8448_50a7a1165ff7, "VP9_VLD_10bit_Profile2"),
        (0x4c749ef6_6ecf_48aa_8448_50a7a1165ff7, "VP9_VLD_10bit_Profile2(alt)"),
        (0x6f3ec719_3735_42cc_8063_65cc3cb36616, "VP8_VLD"),
        (0xee27417f_5e28_4e65_beea_1d26b508adc9, "MPEG2_VLD"),
        (0x86695f12_340e_4f04_9fd3_9253dd327460, "MPEG2and1_VLD"),
        (0x1b81bea3_a0c7_11d3_b984_00c04f2e73c5, "VC1_VLD"),
        (0x1b81bea4_a0c7_11d3_b984_00c04f2e73c5, "VC1_D2010"),
        (0xefd64d74_c9e8_41d7_a5e9_e9b0e39fa319, "MPEG4pt2_VLD_Simple"),
        (0xed418a9f_010d_4eda_9ae3_9a65358d8d2e, "MPEG4pt2_VLD_AdvSimple_NoGMC"),
        (0x32fcfe3f_de46_4a49_861b_ac71110649d5, "VP9_VLD_Profile0(alt)"),
        (0x914c84a3_4078_4fa9_984c_e2f262cb5c9c, "unknown"),
    ];
    table.iter().find(|(u, _)| g(*u) == *p).map(|(_, n)| *n).unwrap_or("unknown")
}

fn is_hevc_444_profile(name: &str) -> bool {
    name.starts_with("HEVC") && (name.contains("444") || name.contains("Main16"))
}

fn guid_str(g: &GUID) -> String {
    format!("{g:?}").to_lowercase()
}

fn subtype_name(g: &GUID) -> String {
    let d = g.data1;
    let b = d.to_le_bytes();
    if g.data2 == 0 && g.data3 == 0x0010 && b.iter().all(|c| c.is_ascii_graphic()) {
        String::from_utf8_lossy(&b).into_owned()
    } else {
        guid_str(g)
    }
}

struct ClipResult {
    json: String,
    ok_444_gpu: bool,
    ok_444_any: bool,
}

/// Map the decoded frame back to the CPU and compute luma/chroma statistics to prove the
/// output isn't blank or chroma-flat.
unsafe fn frame_stats(dec: &Decoder, f: &FrameTex) -> Option<(f64, f64, f64, f64)> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: f.w,
        Height: f.h,
        MipLevels: 1,
        ArraySize: 1,
        Format: f.fmt.dxgi(),
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        MiscFlags: 0,
    };
    let mut st = None;
    dec.device().CreateTexture2D(&desc, None, Some(&mut st)).ok()?;
    let st: ID3D11Texture2D = st?;
    dec.context().CopyResource(&st, &f.tex);
    let mut m = D3D11_MAPPED_SUBRESOURCE::default();
    dec.context().Map(&st, 0, D3D11_MAP_READ, 0, Some(&mut m)).ok()?;
    let base = m.pData as *const u8;
    let pitch = m.RowPitch as usize;
    let (w, h) = (f.w as usize, f.h as usize);
    let mut ys = Vec::with_capacity(w * h / 16);
    let mut us = Vec::with_capacity(w * h / 16);
    for y in (0..h).step_by(4) {
        for x in (0..w).step_by(4) {
            let (yy, uu) = match f.fmt {
                OutFormat::Nv12 => {
                    let yv = *base.add(y * pitch + x) as f64;
                    let uv = *base.add(pitch * h + (y / 2) * pitch + (x & !1)) as f64;
                    (yv, uv)
                }
                OutFormat::P010 => {
                    let yv = (*(base.add(y * pitch + x * 2) as *const u16) >> 6) as f64 / 4.0;
                    let uv = (*(base.add(pitch * h + (y / 2) * pitch + (x & !1) * 2) as *const u16) >> 6) as f64 / 4.0;
                    (yv, uv)
                }
                OutFormat::Ayuv => {
                    let p = base.add(y * pitch + x * 4);
                    (*p.add(2) as f64, *p.add(1) as f64) // V U Y A
                }
                OutFormat::Y410 => {
                    let v = *(base.add(y * pitch + x * 4) as *const u32);
                    (((v >> 10) & 0x3FF) as f64 / 4.0, (v & 0x3FF) as f64 / 4.0)
                }
                OutFormat::Y416 => {
                    let p = base.add(y * pitch + x * 8) as *const u16;
                    ((*p.add(1) >> 8) as f64, (*p >> 8) as f64)
                }
            };
            ys.push(yy);
            us.push(uu);
        }
    }
    dec.context().Unmap(&st, 0);
    let stat = |v: &[f64]| {
        let m = v.iter().sum::<f64>() / v.len() as f64;
        let sd = (v.iter().map(|x| (x - m) * (x - m)).sum::<f64>() / v.len() as f64).sqrt();
        (m, sd)
    };
    let (ym, ysd) = stat(&ys);
    let (um, usd) = stat(&us);
    Some((ym, ysd, um, usd))
}

fn test_clip(gpu: &Gpu, clip: &Clip) -> ClipResult {
    let aus = split_access_units(clip.codec, clip.data);
    let sps = if clip.codec == Codec::Hevc { hevc_sps_info(clip.data) } else { None };
    let (w, h) = sps.map(|(_, _, w, h)| (w, h)).unwrap_or((640, 360));
    let mut out = format!(
        "{{\"clip\":{},\"bytes\":{},\"access_units\":{},\"sps_chroma_format_idc\":{},\"sps_bit_depth\":{}",
        json_str(clip.name),
        clip.data.len(),
        aus.len(),
        sps.map_or("null".into(), |s| s.0.to_string()),
        sps.map_or("null".into(), |s| s.1.to_string())
    );
    let mut ok_gpu = false;
    let mut ok_any = false;
    match Decoder::new_with(gpu, clip.codec, w, h, clip.is_444, None, true) {
        Err(e) => out.push_str(&format!(",\"error\":{}", json_str(&format!("create decoder: {e}")))),
        Ok(mut dec) => {
            let mut frames = 0u32;
            let mut err: Option<String> = None;
            let t0 = std::time::Instant::now();
            for au in &aus {
                match dec.decode(&au.data, au.keyframe) {
                    Ok(n) => frames += n,
                    Err(e) => {
                        err = Some(format!("decode: {e}"));
                        break;
                    }
                }
            }
            let before_drain = frames;
            if err.is_none() {
                match dec.drain() {
                    Ok(n) => frames += n,
                    Err(e) => err = Some(format!("drain: {e}")),
                }
            }
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            let fmt = dec.out_fmt.map(|f| f.name()).unwrap_or("none");
            let offered: Vec<String> = dec.available_outputs().iter().map(|g| json_str(&subtype_name(g))).collect();
            out.push_str(&format!(
                ",\"decoder\":{},\"d3d11\":{},\"frames_out\":{},\"frames_out_before_drain\":{},\"output_format\":{},\"output_on_gpu\":{},\"stream_changes\":{},\"offered_outputs\":[{}],\"ms\":{:.1}",
                json_str(&dec.info.name),
                dec.d3d,
                frames,
                before_drain,
                json_str(fmt),
                dec.last_output_gpu,
                dec.stream_changes,
                offered.join(","),
                ms
            ));
            if let Some(f) = dec.frame.as_ref() {
                if let Some((ym, ysd, um, usd)) = unsafe { frame_stats(&dec, f) } {
                    out.push_str(&format!(
                        ",\"last_frame\":{{\"w\":{},\"h\":{},\"luma_mean\":{ym:.1},\"luma_sd\":{ysd:.1},\"cb_mean\":{um:.1},\"cb_sd\":{usd:.1}}}",
                        f.w, f.h
                    ));
                    let sane = ysd > 10.0 && usd > 3.0;
                    out.push_str(&format!(",\"content_sane\":{sane}"));
                    if clip.is_444 && frames > 0 && dec.out_fmt.is_some_and(|f| f.is_444()) && sane {
                        ok_any = true;
                        ok_gpu = dec.last_output_gpu && dec.d3d;
                    }
                }
            }
            if let Some(e) = err {
                out.push_str(&format!(",\"error\":{}", json_str(&e)));
            }
        }
    }
    out.push('}');
    ClipResult { json: out, ok_444_gpu: ok_gpu, ok_444_any: ok_any }
}

/// Quick verdict used for ClientHello caps: decode the embedded 8-bit 4:4:4 clip.
pub fn hevc444_supported() -> bool {
    static R: OnceLock<bool> = OnceLock::new();
    *R.get_or_init(|| {
        let Ok(gpu) = Gpu::new() else { return false };
        test_clip(&gpu, &CLIPS[2]).ok_444_gpu
    })
}

pub fn run_json() -> String {
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(e) => return format!("{{\"error\":{}}}", json_str(&format!("D3D11/MF init failed: {e}"))),
    };
    let mut j = String::from("{");
    j.push_str(&format!(
        "\"adapter\":{{\"name\":{},\"vendor_id\":\"0x{:04x}\",\"device_id\":\"0x{:04x}\",\"feature_level\":\"0x{:x}\"}}",
        json_str(&gpu.adapter_name),
        gpu.vendor_id,
        gpu.device_id,
        gpu.feature_level
    ));

    // --- Decoder MFTs
    j.push_str(",\"decoder_mfts\":[");
    let mut first = true;
    for (cname, sub) in [("HEVC", codec_subtype(Codec::Hevc)), ("H.264", codec_subtype(Codec::H264)), ("AV1", MFVideoFormat_AV1)] {
        let flags = MFT_ENUM_FLAG_ALL | MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_UNTRUSTED_STOREMFT;
        match enum_decoders(&sub, flags) {
            Ok(list) => {
                for (info, act) in list {
                    let mut d3d11_aware = "null".to_string();
                    if !info.is_async() {
                        if let Ok(t) = unsafe { act.ActivateObject::<IMFTransform>() } {
                            if let Ok(a) = unsafe { t.GetAttributes() } {
                                d3d11_aware = (unsafe { a.GetUINT32(&MF_SA_D3D11_AWARE) }.unwrap_or(0) != 0).to_string();
                            }
                            let _ = unsafe { act.ShutdownObject() };
                        }
                    }
                    if !first {
                        j.push(',');
                    }
                    first = false;
                    j.push_str(&format!(
                        "{{\"codec\":{},\"name\":{},\"clsid\":{},\"hardware\":{},\"async\":{},\"flags\":\"0x{:x}\",\"d3d11_aware\":{},\"hardware_url\":{}}}",
                        json_str(cname),
                        json_str(&info.name),
                        json_str(&guid_str(&info.clsid)),
                        info.is_hardware(),
                        info.is_async(),
                        info.flags,
                        d3d11_aware,
                        info.hardware_url.as_deref().map_or("null".into(), json_str)
                    ));
                }
            }
            Err(e) => {
                if !first {
                    j.push(',');
                }
                first = false;
                j.push_str(&format!("{{\"codec\":{},\"error\":{}}}", json_str(cname), json_str(&e.to_string())));
            }
        }
    }
    j.push(']');

    // --- D3D11 video decoder profiles
    let mut hevc444_profiles: Vec<String> = Vec::new();
    j.push_str(",\"d3d11_decoder_profiles\":[");
    match gpu.device.cast::<ID3D11VideoDevice>() {
        Ok(vd) => unsafe {
            let n = vd.GetVideoDecoderProfileCount();
            let fmts = [
                ("NV12", DXGI_FORMAT_NV12),
                ("P010", DXGI_FORMAT_P010),
                ("P016", DXGI_FORMAT_P016),
                ("YUY2", DXGI_FORMAT_YUY2),
                ("Y210", DXGI_FORMAT_Y210),
                ("Y216", DXGI_FORMAT_Y216),
                ("AYUV", DXGI_FORMAT_AYUV),
                ("Y410", DXGI_FORMAT_Y410),
                ("Y416", DXGI_FORMAT_Y416),
                ("420_OPAQUE", DXGI_FORMAT_420_OPAQUE),
            ];
            for i in 0..n {
                let Ok(p) = vd.GetVideoDecoderProfile(i) else { continue };
                let name = profile_name(&p);
                let ok: Vec<String> = fmts
                    .iter()
                    .filter(|(_, f)| vd.CheckVideoDecoderFormat(&p, *f).map(|b| b.as_bool()).unwrap_or(false))
                    .map(|(n, _)| json_str(n))
                    .collect();
                if is_hevc_444_profile(name) && !ok.is_empty() {
                    hevc444_profiles.push(name.to_string());
                }
                if i > 0 {
                    j.push(',');
                }
                j.push_str(&format!(
                    "{{\"guid\":{},\"name\":{},\"formats\":[{}]}}",
                    json_str(&guid_str(&p)),
                    json_str(name),
                    ok.join(",")
                ));
            }
        },
        Err(e) => j.push_str(&format!("{{\"error\":{}}}", json_str(&e.to_string()))),
    }
    j.push(']');
    j.push_str(&format!(
        ",\"hevc444_d3d11_profiles\":[{}]",
        hevc444_profiles.iter().map(|s| json_str(s)).collect::<Vec<_>>().join(",")
    ));

    // --- Does the HEVC MFT accept an input type that declares Main 4:4:4 (MF_MT_MPEG2_PROFILE = 6)?
    let accepts = match Decoder::new_with(&gpu, Codec::Hevc, 640, 360, true, Some(eAVEncH265VProfile_Main_444_8.0 as u32), true) {
        Ok(d) => format!("{{\"accepted\":true,\"decoder\":{},\"d3d11\":{}}}", json_str(&d.info.name), d.d3d),
        Err(e) => format!("{{\"accepted\":false,\"error\":{}}}", json_str(&e.to_string())),
    };
    j.push_str(&format!(",\"mf_hevc_input_type_main444\":{accepts}"));

    // --- Real decode tests
    j.push_str(",\"decode_tests\":[");
    let mut ok444_gpu = false;
    let mut ok444_any = false;
    for (i, c) in CLIPS.iter().enumerate() {
        let r = test_clip(&gpu, c);
        if c.name == "hevc_rext_444_8" {
            ok444_gpu = r.ok_444_gpu;
            ok444_any = r.ok_444_any;
        }
        if i > 0 {
            j.push(',');
        }
        j.push_str(&r.json);
    }
    j.push(']');
    j.push_str(&format!(
        ",\"hevc444_decode\":{ok444_gpu},\"hevc444_decode_any_path\":{ok444_any},\"verdict\":{}}}",
        json_str(if ok444_gpu {
            "HEVC 4:4:4 (8-bit RExt) decodes on the GPU via Media Foundation + D3D11: sharp mode supported"
        } else if ok444_any {
            "HEVC 4:4:4 decodes only without D3D11 output (software path): sharp mode not advertised"
        } else {
            "HEVC 4:4:4 does not decode via Media Foundation on this machine: sharp mode not advertised"
        })
    ));
    j
}
