//! glide-client: Glide remote desktop viewer.
//!
//! Usage: glide-client <host[:port]> [--password PW] [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd]
//!                     [--bench SECONDS] [--probe]

use glide::net::Connection;
use glide::protocol::{self, ClientMsg, Mode};
use std::process::ExitCode;

#[derive(Debug, Clone)]
pub struct Args {
    host: Option<String>,
    password: Option<String>,
    /// None = default (hybrid if this machine decodes HEVC 4:4:4, else fast).
    mode: Option<Mode>,
    ctrl_as_cmd: bool,
    bench: Option<f64>,
    probe: bool,
    /// Reverse-connect: listen on this port and let the host dial in.
    listen: Option<u16>,
    /// Clipboard sync (GUI viewer only); off with --no-clipboard.
    clipboard: bool,
    /// Headless Win32 clipboard self-test (no connection).
    clipboard_selftest: bool,
}

const USAGE: &str = "usage: glide-client <host[:port]> [--password PW] [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd] [--no-clipboard] [--bench SECONDS] [--probe]
       glide-client --listen [PORT] [options...]

  host[:port]        Glide host (default port 7420)
  --listen [PORT]    reverse connect: listen on 0.0.0.0:PORT (default 7420) and accept ONE
                     connection from the host (e.g. glide-host --connect); same protocol
  --password PW      session password (else env GLIDE_PASSWORD, else prompt)
  --mode M           fast = 4:2:0 only; sharp = 4:4:4 every frame; hybrid = 4:2:0 while moving +
                     4:4:4 refinement at rest. Default: hybrid if this PC decodes HEVC 4:4:4, else fast
  --no-ctrl-as-cmd   don't swap Ctrl<->Win (default maps Ctrl->Cmd, Win->Control)
  --no-clipboard     don't sync the clipboard (text + images) with the host
  --bench SECONDS    headless: connect, decode for N seconds, print one JSON line
  --probe            print decoder capabilities as JSON (no connection)
  --clipboard-selftest  exercise the Win32 clipboard path headlessly (no connection; run over SSH)

In the viewer: F11 or Alt+Enter toggles borderless fullscreen.";

fn parse_args() -> Result<Args, String> {
    let mut a = Args { host: None, password: None, mode: None, ctrl_as_cmd: true, bench: None, probe: false, listen: None, clipboard: true, clipboard_selftest: false };
    let mut it = std::env::args().skip(1).peekable();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--password" => a.password = Some(it.next().ok_or("--password needs a value")?),
            "--mode" => {
                a.mode = Some(match it.next().as_deref() {
                    Some("fast") => Mode::Fast,
                    Some("sharp") => Mode::Sharp,
                    Some("hybrid") => Mode::Hybrid,
                    _ => return Err("--mode must be fast, sharp or hybrid".into()),
                })
            }
            "--no-ctrl-as-cmd" => a.ctrl_as_cmd = false,
            "--no-clipboard" => a.clipboard = false,
            "--clipboard-selftest" => a.clipboard_selftest = true,
            "--bench" => {
                let v = it.next().ok_or("--bench needs SECONDS")?;
                a.bench = Some(v.parse::<f64>().map_err(|_| format!("bad --bench value {v}"))?);
            }
            "--probe" => a.probe = true,
            "--listen" => {
                // Optional PORT argument.
                let port = match it.peek() {
                    Some(v) if v.parse::<u16>().is_ok() => it.next().unwrap().parse().unwrap(),
                    _ => protocol::DEFAULT_PORT,
                };
                a.listen = Some(port);
            }
            "-h" | "--help" => return Err(String::new()),
            s if s.starts_with("--") => return Err(format!("unknown option {s}")),
            s => {
                if a.host.is_some() {
                    return Err(format!("unexpected argument {s}"));
                }
                a.host = Some(s.to_string());
            }
        }
    }
    if !a.probe && !a.clipboard_selftest && a.host.is_none() && a.listen.is_none() {
        return Err("missing host".into());
    }
    Ok(a)
}

fn get_password(a: &Args) -> String {
    if let Some(p) = &a.password {
        return p.clone();
    }
    if let Ok(p) = std::env::var("GLIDE_PASSWORD") {
        if !p.is_empty() {
            return p;
        }
    }
    prompt_password()
}

fn prompt_password() -> String {
    use std::io::Write;
    eprint!("Password: ");
    let _ = std::io::stderr().flush();
    #[cfg(windows)]
    let _echo = glide::win::console::EchoOff::new();
    let mut s = String::new();
    let _ = std::io::stdin().read_line(&mut s);
    eprintln!();
    s.trim_end_matches(['\r', '\n']).to_string()
}

fn client_name() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "glide-client".into())
}

fn main() -> ExitCode {
    // Physical pixels everywhere (monitor sizes for ClientHello/ViewSize, window, swap chain).
    #[cfg(windows)]
    glide::win::set_dpi_awareness();
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            if !e.is_empty() {
                eprintln!("error: {e}");
            }
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };

    if args.clipboard_selftest {
        #[cfg(windows)]
        {
            return match glide::win::clipboard::selftest() {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            };
        }
        #[cfg(not(windows))]
        {
            eprintln!("--clipboard-selftest is only available on Windows");
            return ExitCode::from(1);
        }
    }

    if args.probe {
        #[cfg(windows)]
        {
            println!("{}", glide::win::probe::run_json());
            return ExitCode::SUCCESS;
        }
        #[cfg(not(windows))]
        {
            eprintln!("--probe is only available on Windows");
            return ExitCode::from(1);
        }
    }

    let host = match (&args.host, args.listen) {
        (Some(h), _) => h.clone(),
        (None, Some(p)) => format!("listen:{p}"),
        _ => unreachable!(),
    };
    let password = get_password(&args);

    // Capabilities: HEVC 4:2:0 + H.264 always; HEVC 4:4:4 only if this machine can decode it.
    #[allow(unused_mut)]
    let mut caps = protocol::CAP_HEVC_420 | protocol::CAP_H264_420;
    #[cfg(windows)]
    {
        if glide::win::probe::hevc444_supported() {
            caps |= protocol::CAP_HEVC_444;
        }
        // Clipboard sync (§5) needs the viewer window; the headless bench never advertises it.
        if args.clipboard && args.bench.is_none() {
            caps |= protocol::CAP_CLIPBOARD;
        }
    }
    let has444 = caps & protocol::CAP_HEVC_444 != 0;
    let mode = match args.mode {
        None => {
            if has444 { Mode::Hybrid } else { Mode::Fast }
        }
        Some(m @ (Mode::Sharp | Mode::Hybrid)) if !has444 => {
            eprintln!("note: --mode {} requested but this machine can't decode HEVC 4:4:4; using fast", m.name());
            Mode::Fast
        }
        Some(m) => m,
    };

    #[cfg(windows)]
    let (view_w, view_h, max_fps) = glide::win::display_info();
    #[cfg(not(windows))]
    let (view_w, view_h, max_fps) = (3840u16, 2160u16, 120u8);

    // GLIDE_VIEW=WxH overrides the reported view size (e.g. to bench at 4K from an SSH session).
    let (view_w, view_h) = std::env::var("GLIDE_VIEW")
        .ok()
        .and_then(|v| {
            let (w, h) = v.split_once('x')?;
            Some((w.parse().ok()?, h.parse().ok()?))
        })
        .unwrap_or((view_w, view_h));

    let hello = ClientMsg::ClientHello {
        version: protocol::PROTOCOL_VERSION,
        codec_caps: caps,
        view_w,
        view_h,
        mode: mode as u8,
        max_fps,
        client_name: client_name(),
    };

    // GUI viewer: the window appears immediately and (re)connects/listens forever.
    if args.bench.is_none() {
        #[cfg(windows)]
        {
            use glide::win::app::{Connector, Options, Target};
            let target = match args.listen {
                Some(port) => Target::Listen(port),
                None => Target::Connect(host.clone()),
            };
            let opts = Options { ctrl_as_cmd: args.ctrl_as_cmd, mode, host_label: host };
            return match glide::win::app::run(Connector { target, password, hello }, opts) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            };
        }
        #[cfg(not(windows))]
        {
            eprintln!("the viewer window is only available on Windows (use --bench here)");
            return ExitCode::from(1);
        }
    }

    // Bench: one-shot connection.
    let res = match args.listen {
        Some(port) => Connection::listen(port, &password, &hello),
        None => Connection::connect(&host, &password, &hello),
    };
    let conn = match res {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: connect to {host}: {e}");
            if let Some(secs) = args.bench {
                println!(
                    "{{\"host\":{},\"seconds\":{secs},\"frames\":0,\"errors\":[{}]}}",
                    glide::util::json_str(&host),
                    glide::util::json_str(&format!("connect: {e}"))
                );
            }
            return ExitCode::from(1);
        }
    };
    eprintln!(
        "connected to {} ({}x{} {} {}, scale {}), caps={:#05b}, mode={}",
        conn.host_name,
        conn.config.width,
        conn.config.height,
        conn.config.codec.name(),
        conn.config.chroma_name(),
        conn.config.scale,
        caps,
        mode.name()
    );

    if let Some(secs) = args.bench {
        #[cfg(windows)]
        let line = {
            let (mut dec, mut sharp) =
                match (glide::win::bench_decoder::MfBenchDecoder::new(), glide::win::bench_decoder::MfBenchDecoder::new()) {
                    (Ok(d), Ok(s)) => (d, s),
                    (Err(e), _) | (_, Err(e)) => {
                        eprintln!("error: D3D11/MF init failed: {e}");
                        return ExitCode::from(1);
                    }
                };
            glide::bench::run(conn, secs, &mut dec, &mut sharp)
        };
        #[cfg(not(windows))]
        let line = glide::bench::run(conn, secs, &mut glide::bench::NullDecoder, &mut glide::bench::NullDecoder);
        println!("{line}");
        return ExitCode::SUCCESS;
    }

    unreachable!()
}
