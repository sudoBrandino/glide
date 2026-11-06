//! D3D11 device creation (video support + multithread protection) and the MF DXGI device manager.

use windows::core::{Interface, Result};
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Media::MediaFoundation::*;

pub struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub manager: IMFDXGIDeviceManager,
    pub adapter_name: String,
    pub vendor_id: u32,
    pub device_id: u32,
    pub feature_level: u32,
}

pub fn mf_startup() -> Result<()> {
    static ONCE: std::sync::Once = std::sync::Once::new();
    let mut r = Ok(());
    ONCE.call_once(|| unsafe {
        let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
        r = MFStartup(0x0002_0070 /* MF_VERSION */, 0 /* MFSTARTUP_FULL */);
    });
    r
}

impl Gpu {
    pub fn new() -> Result<Gpu> {
        mf_startup()?;
        unsafe {
            let mut device = None;
            let mut context = None;
            let mut fl = D3D_FEATURE_LEVEL::default();
            let flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            let levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0];
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                flags,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                Some(&mut fl),
                Some(&mut context),
            )?;
            let device: ID3D11Device = device.unwrap();
            let context: ID3D11DeviceContext = context.unwrap();
            // Decoder (MF) and our renderer share the immediate context.
            let mt: ID3D11Multithread = context.cast()?;
            let _ = mt.SetMultithreadProtected(true);

            let mut token = 0u32;
            let mut manager = None;
            MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
            let manager: IMFDXGIDeviceManager = manager.unwrap();
            manager.ResetDevice(&device, token)?;

            let dxgi: IDXGIDevice = device.cast()?;
            let adapter = dxgi.GetAdapter()?;
            let desc = adapter.GetDesc()?;
            let n = desc.Description.iter().position(|&c| c == 0).unwrap_or(desc.Description.len());
            Ok(Gpu {
                device,
                context,
                manager,
                adapter_name: String::from_utf16_lossy(&desc.Description[..n]),
                vendor_id: desc.VendorId,
                device_id: desc.DeviceId,
                feature_level: fl.0 as u32,
            })
        }
    }

    pub fn factory(&self) -> Result<IDXGIFactory2> {
        unsafe {
            let dxgi: IDXGIDevice = self.device.cast()?;
            let adapter = dxgi.GetAdapter()?;
            adapter.GetParent()
        }
    }

    /// Block until all GPU work submitted so far has completed.
    pub fn wait_idle(&self, query: &ID3D11Query) {
        unsafe {
            self.context.End(query);
            let mut done = windows::core::BOOL(0);
            for _ in 0..200_000 {
                let _ = self.context.GetData(query, Some(&mut done as *mut _ as *mut _), 4, 0);
                if done.as_bool() {
                    return;
                }
                std::hint::spin_loop();
            }
        }
    }

    pub fn event_query(&self) -> Result<ID3D11Query> {
        unsafe {
            let mut q = None;
            self.device.CreateQuery(&D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 }, Some(&mut q))?;
            Ok(q.unwrap())
        }
    }
}
