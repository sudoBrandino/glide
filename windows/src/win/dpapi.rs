//! DPAPI (`CryptProtectData`, current-user scope): only this Windows account on this PC can
//! decrypt. Used for the viewer's identity key (`identity.dpapi`, see `crate::identity`).
//! (The v1 `password.dpapi` file is no longer read or written.)

use windows::core::PCWSTR;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Cryptography::*;

/// Extra entropy so other apps using DPAPI under the same account can't trivially reuse the blob.
pub const IDENTITY_ENTROPY: &[u8] = b"glide viewer identity key v2";

fn blob(b: &[u8]) -> CRYPT_INTEGER_BLOB {
    CRYPT_INTEGER_BLOB { cbData: b.len() as u32, pbData: b.as_ptr() as *mut u8 }
}

fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
    unsafe {
        let v = if out.pbData.is_null() { Vec::new() } else { std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec() };
        if !out.pbData.is_null() {
            let _ = LocalFree(Some(HLOCAL(out.pbData as *mut _)));
        }
        v
    }
}

pub fn protect(data: &[u8], entropy: &[u8], description: &str) -> Result<Vec<u8>, String> {
    let (inb, ent) = (blob(data), blob(entropy));
    let desc: Vec<u16> = description.encode_utf16().chain(std::iter::once(0)).collect();
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptProtectData(&inb, PCWSTR(desc.as_ptr()), Some(&ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut out)
            .map_err(|e| format!("CryptProtectData: {e}"))?;
    }
    Ok(take(out))
}

pub fn unprotect(data: &[u8], entropy: &[u8]) -> Result<Vec<u8>, String> {
    let (inb, ent) = (blob(data), blob(entropy));
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptUnprotectData(&inb, None, Some(&ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut out)
            .map_err(|e| format!("CryptUnprotectData: {e}"))?;
    }
    Ok(take(out))
}
