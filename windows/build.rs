//! Embeds the Windows resources (icon, manifest, password dialog, version info) into
//! glide-client.exe. Uses MinGW `windres` for the GNU target (set `WINDRES` to override).
//! Non-Windows targets (unit tests on macOS) skip this entirely.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    for f in ["res/glide.rc", "res/glide.ico", "res/glide.manifest"] {
        println!("cargo:rerun-if-changed={f}");
    }
    println!("cargo:rerun-if-env-changed=WINDRES");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("gnu") {
        println!("cargo:warning=resources (icon, password dialog) are only built for the windows-gnu target");
        return;
    }
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("glide-res.o");
    let windres = std::env::var("WINDRES").unwrap_or_else(|_| {
        let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
        if cfg!(windows) { "windres".into() } else { format!("{arch}-w64-mingw32-windres") }
    });
    let status = Command::new(&windres)
        .current_dir("res")
        .args(["--input-format=rc", "--output-format=coff", "-i", "glide.rc", "-o"])
        .arg(&out)
        .status();
    match status {
        Ok(s) if s.success() => println!("cargo:rustc-link-arg-bins={}", out.display()),
        Ok(s) => panic!("{windres} failed ({s})"),
        Err(e) => panic!("cannot run {windres}: {e} (install mingw-w64 or set WINDRES)"),
    }
}
