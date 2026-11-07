//! Embeds the Windows resources (icon, manifest, pairing dialog, version info) into
//! glide-client.exe.
//! - windows-gnu: MinGW `windres` (`WINDRES` overrides; `<arch>-w64-mingw32-windres` when cross-compiling).
//! - windows-msvc: `rc.exe` from the Windows SDK via the `embed-resource` crate.
//! Non-Windows targets (unit tests on macOS/Linux) skip this entirely.

use std::path::PathBuf;
use std::process::Command;

const FILES: [&str; 3] = ["glide.rc", "glide.ico", "glide.manifest"];

fn main() {
    for f in FILES {
        println!("cargo:rerun-if-changed=res/{f}");
    }
    println!("cargo:rerun-if-env-changed=WINDRES");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    match std::env::var("CARGO_CFG_TARGET_ENV").as_deref() {
        Ok("gnu") => windres(&out_dir),
        Ok("msvc") => msvc(&out_dir),
        other => println!("cargo:warning=no resource compiler for target env {other:?}; exe has no icon/dialog"),
    }
}

fn windres(out_dir: &std::path::Path) {
    let out = out_dir.join("glide-res.o");
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

fn msvc(out_dir: &std::path::Path) {
    // Copy next to each other in OUT_DIR (which embed-resource passes to rc.exe as /I) so the
    // relative ICON/manifest paths resolve regardless of rc.exe's working directory.
    for f in FILES {
        std::fs::copy(PathBuf::from("res").join(f), out_dir.join(f)).expect("copy resource file");
    }
    embed_resource::compile(out_dir.join("glide.rc"), embed_resource::NONE).manifest_required().unwrap();
    // The manifest is embedded as resource 1 (RT_MANIFEST); don't let link.exe add its own.
    println!("cargo:rustc-link-arg-bins=/MANIFEST:NO");
}
