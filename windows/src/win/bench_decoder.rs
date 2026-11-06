//! `BenchDecoder` implementation on the real MF + D3D11 decoder. Waits for GPU
//! completion after each frame so decode_ms reflects actual decode + copy time.

use super::d3d::Gpu;
use super::decoder::Decoder;
use crate::bench::BenchDecoder;
use crate::protocol::VideoConfig;
use crate::util::json_str;
use windows::Win32::Graphics::Direct3D11::ID3D11Query;

pub struct MfBenchDecoder {
    gpu: Gpu,
    dec: Option<Decoder>,
    query: ID3D11Query,
}

impl MfBenchDecoder {
    pub fn new() -> windows::core::Result<Self> {
        let gpu = Gpu::new()?;
        let query = gpu.event_query()?;
        Ok(MfBenchDecoder { gpu, dec: None, query })
    }
}

impl BenchDecoder for MfBenchDecoder {
    fn configure(&mut self, cfg: &VideoConfig) -> Result<(), String> {
        self.dec = None; // drop the old MFT first
        self.dec = Some(Decoder::new(&self.gpu, cfg).map_err(|e| e.to_string())?);
        Ok(())
    }

    fn decode(&mut self, data: &[u8], keyframe: bool) -> Result<u32, String> {
        let dec = self.dec.as_mut().ok_or("no decoder")?;
        let n = dec.decode(data, keyframe).map_err(|e| e.to_string())?;
        if n > 0 {
            self.gpu.wait_idle(&self.query);
        }
        Ok(n)
    }

    fn describe_json(&self) -> String {
        match &self.dec {
            None => format!("{{\"name\":null,\"adapter\":{}}}", json_str(&self.gpu.adapter_name)),
            Some(d) => format!(
                "{{\"name\":{},\"hw\":{},\"d3d11\":{},\"output_format\":{},\"output_on_gpu\":{},\"adapter\":{}}}",
                json_str(&d.info.name),
                d.d3d,
                d.d3d,
                json_str(d.out_fmt.map(|f| f.name()).unwrap_or("none")),
                d.last_output_gpu,
                json_str(&self.gpu.adapter_name)
            ),
        }
    }
}
