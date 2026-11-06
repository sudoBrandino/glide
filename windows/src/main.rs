//! glide-client: Glide remote desktop viewer.
//!
//! Usage: glide-client [host[:port] | --listen [PORT]] [--password PW] [--mode fast|sharp|hybrid]
//!                     [--no-ctrl-as-cmd] [--bench SECONDS] [--probe] [--forget-password]
//! With no target, the viewer uses %APPDATA%\Glide\config.json (default: listen on 7420).

use glide::config::{self, Store, TargetSpec};
use glide::net::Connection;
use glide::protocol::{self, ClientMsg, Mode};
use std::process::ExitCode;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Args {
    host: Option<String>,
    password: Option<String>,
    /// None = config, else automatic (hybrid if this machine decodes HEVC 4:4:4, else fast).
    mode: Option<Mode>,
    /// None = config (default on).
    ctrl_as_cmd: Option<bool>,
    bench: Option<f64>,
    /// Start in latency test mode (docs/LATENCY.md).
    latency_test: bool,
    probe: bool,
    /// Reverse-connect: listen on this port and let the host dial in.
    listen: Option<u16>,
    forget_password: bool,
    /// Clipboard sync (GUI viewer only). None = config ("clipboard", default on); --no-clipboard.
    clipboard: Option<bool>,
    /// Headless Win32 clipboard self-test (no connection).
    clipboard_selftest: bool,
    /// Also sync clipboard content marked private (password managers).
    clipboard_sync_secrets: bool,
    /// Audio playback. None = config ("audio", default on); --no-audio.
    audio: Option<bool>,
    /// Headless WASAPI check (plays digital silence only), seconds.
    audio_selftest: Option<f64>,
}

const USAGE: &str = "usage: glide-client [host[:port] | --listen [PORT]] [options...]

  (no target)        use the config file: dial its \"host\" if set, else listen on its
                     \"listen_port\" (default 7420)
  host[:port]        dial a Glide host (default port 7420)
  --listen [PORT]    reverse connect: listen on 0.0.0.0:PORT (default 7420) and let the host
                     dial in (glide-host --connect); same protocol
  --password PW      session password (else env GLIDE_PASSWORD, else the saved password, else a
                     password dialog with a \"Remember\" option)
  --mode M           fast = 4:2:0 only; sharp = 4:4:4 every frame; hybrid = 4:2:0 while moving +
                     4:4:4 refinement at rest. Default: config, else hybrid if this PC decodes
                     HEVC 4:4:4, else fast
  --no-ctrl-as-cmd   don't map Ctrl->Cmd / Win->Control (also --ctrl-as-cmd to force it on)
  --no-clipboard     don't sync the clipboard (text + images) with the host (config: \"clipboard\")
  --forget-password  delete the saved (DPAPI-encrypted) password and exit
  --no-audio         don't stream the Mac's sound (config \"audio\"; Ctrl+Alt+Shift+A mutes)
  --audio-selftest [SECONDS]
                     headless: open the default output device and run the audio path on
                     digital silence (inaudible) for N seconds (default 3); print JSON
  --clipboard-sync-secrets  also send clipboard content that password managers mark private
                     (default: respected, not sent). Env GLIDE_CLIPBOARD_SYNC_SECRETS=1, or config
                     \"clipboard_sync_secrets\": true
  --bench SECONDS    headless: connect, decode for N seconds, print one JSON line
  --probe            print decoder capabilities as JSON (no connection)
  --latency-test     start in latency test mode: read the host's block-code test pattern
                     (glide-probe --pattern-only on the Mac) back from the decoded picture and
                     report true glass-to-glass latency (Ctrl+Alt+Shift+L toggles; docs/LATENCY.md)
  --clipboard-selftest  exercise the Win32 clipboard path headlessly (no connection; run over SSH)

Config: %APPDATA%\\Glide\\config.json (GLIDE_CONFIG_DIR overrides the folder); the saved
password is password.dpapi next to it (only this Windows account can decrypt it).

Viewer hotkeys (handled locally, never sent to the Mac; F11 / Alt+Enter also toggle fullscreen):";

fn parse_args() -> Result<Args, String> {
    parse_args_from(std::env::args().skip(1))
}

fn parse_args_from(args: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = args.into_iter().peekable();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--password" => a.password = Some(it.next().ok_or("--password needs a value")?),
            "--mode" => {
                let v = it.next().unwrap_or_default();
                a.mode = Some(config::mode_from_str(&v).ok_or("--mode must be fast, sharp or hybrid")?);
            }
            "--no-ctrl-as-cmd" => a.ctrl_as_cmd = Some(false),
            "--ctrl-as-cmd" => a.ctrl_as_cmd = Some(true),
            "--forget-password" => a.forget_password = true,
            "--no-clipboard" => a.clipboard = Some(false),
            "--clipboard-selftest" => a.clipboard_selftest = true,
            "--clipboard-sync-secrets" => a.clipboard_sync_secrets = true,
            "--bench" => {
                let v = it.next().ok_or("--bench needs SECONDS")?;
                a.bench = Some(v.parse::<f64>().map_err(|_| format!("bad --bench value {v}"))?);
            }
            "--probe" => a.probe = true,
            "--latency-test" => a.latency_test = true,
            "--no-audio" => a.audio = Some(false),
            "--audio-selftest" => {
                let secs = match it.peek() {
                    Some(v) if v.parse::<f64>().is_ok() => it.next().unwrap().parse().unwrap(),
                    _ => 3.0,
                };
                a.audio_selftest = Some(secs);
            }
            "--listen" => {
                // Optional PORT argument.
                let port = match it.peek() {
                    Some(v) if v.parse::<u16>().is_ok() => it.next().unwrap().parse().unwrap(),
                    _ => protocol::DEFAULT_PORT,
                };
                a.listen = Some(port);
            }
            "-h" | "--help" | "/?" => return Err(String::new()),
            s if s.starts_with("--") => return Err(format!("unknown option {s}")),
            s => {
                if a.host.is_some() {
                    return Err(format!("unexpected argument {s}"));
                }
                a.host = Some(s.to_string());
            }
        }
    }
    Ok(a)
}

#[cfg(windows)]
type PasswordSource = glide::win::app::PasswordSource;
#[cfg(not(windows))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
enum PasswordSource {
    Cli,
    Env,
    Saved,
    Prompted,
}

/// CLI, then GLIDE_PASSWORD, then the DPAPI-saved password. None = must ask.
fn known_password(a: &Args, dir: Option<&std::path::Path>) -> Option<(String, PasswordSource)> {
    if let Some(p) = &a.password {
        return Some((p.clone(), PasswordSource::Cli));
    }
    if let Ok(p) = std::env::var("GLIDE_PASSWORD") {
        if !p.is_empty() {
            return Some((p, PasswordSource::Env));
        }
    }
    #[cfg(windows)]
    if let Some(p) = dir.and_then(glide::win::dpapi::load_password) {
        return Some((p, PasswordSource::Saved));
    }
    let _ = dir;
    None
}

/// GUI: the password dialog (optionally saving it). Some(None) = user cancelled.
#[cfg(windows)]
fn dialog_password(dir: Option<&std::path::Path>, target: &str) -> Option<Option<(String, PasswordSource)>> {
    let msg = format!("Enter the password for the Glide host ({target}).");
    match glide::win::prompt::ask_password(None, &msg, true) {
        Ok(Some(a)) => {
            let mut src = PasswordSource::Prompted;
            if a.remember {
                match dir.map(|d| glide::win::dpapi::store_password(d, &a.password)) {
                    Some(Ok(())) => src = PasswordSource::Saved,
                    Some(Err(e)) => eprintln!("warning: cannot save password: {e}"),
                    None => eprintln!("warning: no config folder; password not saved"),
                }
            }
            Some(Some((a.password, src)))
        }
        Ok(None) => Some(None),
        Err(e) => {
            eprintln!("{e}; falling back to the console");
            None
        }
    }
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
            eprintln!("{USAGE}\n{}", glide::hotkeys::help());
            return ExitCode::from(2);
        }
    };

    #[cfg(windows)]
    glide::win::clipboard::set_sync_secrets(
        args.clipboard_sync_secrets || std::env::var("GLIDE_CLIPBOARD_SYNC_SECRETS").is_ok_and(|v| v == "1"),
    );

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

    if let Some(secs) = args.audio_selftest {
        #[cfg(windows)]
        {
            println!("{}", glide::win::audio::selftest_json(secs));
            return ExitCode::SUCCESS;
        }
        #[cfg(not(windows))]
        {
            let _ = secs;
            eprintln!("--audio-selftest is only available on Windows");
            return ExitCode::from(1);
        }
    }

    // Persistent settings (+ migration of a legacy plaintext password into DPAPI).
    let (mut store, legacy_pw, warnings) = Store::open(config::config_dir());
    for w in &warnings {
        eprintln!("warning: {w}");
    }
    let cfg_dir = store.dir.clone();
    #[cfg(windows)]
    if store.config.clipboard_sync_secrets {
        glide::win::clipboard::set_sync_secrets(true);
    }
    if let Some(pw) = legacy_pw {
        #[cfg(windows)]
        match cfg_dir.as_deref().map(|d| glide::win::dpapi::store_password(d, &pw)) {
            Some(Ok(())) => eprintln!("moved the plaintext password from config.json into password.dpapi (encrypted)"),
            Some(Err(e)) => eprintln!("warning: cannot encrypt the config password ({e}); it was removed from config.json"),
            None => {}
        }
        let _ = pw;
        if let Err(e) = store.save() {
            eprintln!("warning: cannot write config: {e}");
        }
    }
    if args.forget_password {
        #[cfg(windows)]
        let had = cfg_dir.as_deref().map(glide::win::dpapi::forget_password).unwrap_or(false);
        #[cfg(not(windows))]
        let had = false;
        eprintln!("{}", if had { "saved password removed" } else { "no saved password" });
        return ExitCode::SUCCESS;
    }

    let target = config::resolve_target(args.host.as_deref(), args.listen, &store.config);
    let host = match &target {
        TargetSpec::Connect(h) => h.clone(),
        TargetSpec::Listen(p) => format!("listen:{p}"),
    };
    let target_desc = match &target {
        TargetSpec::Connect(h) => h.clone(),
        TargetSpec::Listen(p) => format!("waiting on port {p}"),
    };
    let ctrl_as_cmd = args.ctrl_as_cmd.unwrap_or(store.config.ctrl_as_cmd);

    let (password, password_source) = match known_password(&args, cfg_dir.as_deref()) {
        Some(p) => p,
        None => {
            #[cfg(windows)]
            let from_dialog = if args.bench.is_none() { dialog_password(cfg_dir.as_deref(), &target_desc) } else { None };
            #[cfg(not(windows))]
            let from_dialog: Option<Option<(String, PasswordSource)>> = None;
            let _ = &target_desc;
            match from_dialog {
                Some(Some(p)) => p,
                Some(None) => return ExitCode::SUCCESS, // cancelled
                None => (prompt_password(), PasswordSource::Prompted),
            }
        }
    };

    // Capabilities: HEVC 4:2:0 + H.264 always; HEVC 4:4:4 only if this machine can decode it.
    #[allow(unused_mut)]
    let mut caps = protocol::CAP_HEVC_420 | protocol::CAP_H264_420;
    #[cfg(windows)]
    {
        if glide::win::probe::hevc444_supported() {
            caps |= protocol::CAP_HEVC_444;
        }
        // Clipboard sync (§5) needs the viewer window; the headless bench never advertises it.
        if args.clipboard.unwrap_or(store.config.clipboard) && args.bench.is_none() {
            caps |= protocol::CAP_CLIPBOARD;
        }
    }
    let audio_on = args.audio.unwrap_or(store.config.audio);
    if audio_on {
        caps |= protocol::CAP_AUDIO_PCM;
    }
    let has444 = caps & protocol::CAP_HEVC_444 != 0;
    let (mode, note) = config::resolve_mode(args.mode, &store.config, has444);
    if let Some(n) = note {
        eprintln!("note: {n}");
    }

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
            let target = match target {
                TargetSpec::Listen(port) => Target::Listen(port),
                TargetSpec::Connect(h) => Target::Connect(h),
            };
            let opts = Options {
                ctrl_as_cmd,
                mode,
                host_label: host,
                has444,
                password_source,
                audio: audio_on,
                audio_muted: store.config.audio_muted,
                latency_test: args.latency_test,
                store,
            };
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
    let _ = (ctrl_as_cmd, password_source, &mut store);
    let res = match &target {
        TargetSpec::Listen(port) => Connection::listen(*port, &password, &hello),
        TargetSpec::Connect(h) => Connection::connect(h, &password, &hello),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn p(v: &[&str]) -> Result<Args, String> {
        parse_args_from(v.iter().map(|s| s.to_string()))
    }

    #[test]
    fn no_args_is_valid() {
        assert_eq!(p(&[]).unwrap(), Args::default());
    }

    #[test]
    fn flags_override() {
        let a = p(&["--listen", "--mode", "sharp", "--no-ctrl-as-cmd"]).unwrap();
        assert_eq!(a.listen, Some(protocol::DEFAULT_PORT));
        assert_eq!(a.mode, Some(Mode::Sharp));
        assert_eq!(a.ctrl_as_cmd, Some(false));
        let a = p(&["--listen", "7421", "--password", "x"]).unwrap();
        assert_eq!(a.listen, Some(7421));
        assert_eq!(a.password.as_deref(), Some("x"));
        let a = p(&["mac.local:7420", "--ctrl-as-cmd", "--forget-password", "--no-clipboard", "--no-audio"]).unwrap();
        assert_eq!(a.clipboard, Some(false));
        assert_eq!(a.audio, Some(false));
        assert_eq!(p(&["--audio-selftest"]).unwrap().audio_selftest, Some(3.0));
        assert_eq!(p(&["--audio-selftest", "5"]).unwrap().audio_selftest, Some(5.0));
        assert_eq!(a.host.as_deref(), Some("mac.local:7420"));
        assert_eq!(a.ctrl_as_cmd, Some(true));
        assert!(a.forget_password);
        assert!(p(&["--mode", "ultra"]).is_err());
        assert!(p(&["a", "b"]).is_err());
        assert!(p(&["--nope"]).is_err());
        assert_eq!(p(&["--help"]), Err(String::new()));
    }

    #[test]
    fn cli_overrides_config() {
        let mut c = config::Config::default();
        c.host = Some("cfg-host".into());
        c.set_mode(Mode::Fast);
        let a = p(&["--listen", "--mode", "hybrid"]).unwrap();
        assert_eq!(config::resolve_target(a.host.as_deref(), a.listen, &c), TargetSpec::Listen(7420));
        assert_eq!(config::resolve_mode(a.mode, &c, true).0, Mode::Hybrid);
        let a = p(&[]).unwrap();
        assert_eq!(config::resolve_target(a.host.as_deref(), a.listen, &c), TargetSpec::Connect("cfg-host".into()));
        assert_eq!(config::resolve_mode(a.mode, &c, true).0, Mode::Fast);
        assert!(a.ctrl_as_cmd.unwrap_or(c.ctrl_as_cmd));
    }

    #[test]
    fn password_precedence() {
        let a = p(&["--password", "cli"]).unwrap();
        assert_eq!(known_password(&a, None).map(|x| x.1), Some(PasswordSource::Cli));
    }
}
