//! Saved session password, encrypted with DPAPI (`CryptProtectData`, current user scope) in
//! `<config dir>\password.dpapi`. Only this Windows account on this PC can decrypt it.

use crate::config::PASSWORD_FILE;
use std::path::Path;
use windows::core::w;
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Cryptography::*;

/// Extra entropy so other apps using DPAPI under the same account can't trivially reuse the blob.
const ENTROPY: &[u8] = b"glide viewer session password v1";

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

pub fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
    let (inb, ent) = (blob(data), blob(ENTROPY));
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptProtectData(&inb, w!("Glide session password"), Some(&ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut out)
            .map_err(|e| format!("CryptProtectData: {e}"))?;
    }
    Ok(take(out))
}

pub fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
    let (inb, ent) = (blob(data), blob(ENTROPY));
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptUnprotectData(&inb, None, Some(&ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut out)
            .map_err(|e| format!("CryptUnprotectData: {e}"))?;
    }
    Ok(take(out))
}

/// The saved password, if any (None if missing or undecryptable, e.g. copied from another PC).
pub fn load_password(dir: &Path) -> Option<String> {
    let p = dir.join(PASSWORD_FILE);
    let enc = std::fs::read(&p).ok()?;
    match unprotect(&enc).map(String::from_utf8) {
        Ok(Ok(s)) if !s.is_empty() => Some(s),
        Ok(_) => None,
        Err(e) => {
            eprintln!("warning: cannot decrypt {}: {e}", p.display());
            None
        }
    }
}

pub fn store_password(dir: &Path, pw: &str) -> Result<(), String> {
    let enc = protect(pw.as_bytes())?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let p = dir.join(PASSWORD_FILE);
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, enc).and_then(|_| std::fs::rename(&tmp, &p)).map_err(|e| format!("{}: {e}", p.display()))
}

/// Delete the saved password. Returns true if one existed.
pub fn forget_password(dir: &Path) -> bool {
    std::fs::remove_file(dir.join(PASSWORD_FILE)).is_ok()
}
