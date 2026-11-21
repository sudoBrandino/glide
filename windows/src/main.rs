//! glide-client: Glide remote desktop viewer.
//!
//! Usage: glide-client [host[:port] [--no-listen] | --listen [PORT] | --connection NAME]
//!                     [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd] [--bench SECONDS] [--probe]
//!                     [--forget-host] [--identity] [--list-connections] [--startup]
//! With no target, the viewer uses %APPDATA%\Glide\config.json (default: listen on 7420). With
//! the Mac's address it dials the Mac and also listens, so either side may connect. A plain
//! launch with nothing set up (or from outside the install folder) opens the setup dialog.
//! Security v2: no passwords; the viewer pairs with the host once (docs/PROTOCOL.md §2).

use glide::config::{self, Store, TargetSpec};
use glide::connections;
use glide::net::{Auth, Connection, PairPrompt, PairingUi};
use glide::protocol::{self, ClientMsg, Mode};
use std::process::ExitCode;
use std::sync::Arc;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Args {
    host: Option<String>,
    /// None = config, else automatic (hybrid if this machine decodes HEVC 4:4:4, else fast).
    mode: Option<Mode>,
    /// None = config (default on).
    ctrl_as_cmd: Option<bool>,
    bench: Option<f64>,
    /// Start in latency test mode (docs/LATENCY.md).
    latency_test: bool,
    probe: bool,
    /// Reverse-connect: listen on this port and let the host dial in (with a host: the port
    /// both mode listens on).
    listen: Option<u16>,
    /// With a host: dial only, don't also listen for the Mac.
    no_listen: bool,
    /// Open the setup dialog (also opens by itself when nothing is set up yet).
    setup: bool,
    /// Started by the setup dialog (install / new settings): don't open it again.
    after_setup: bool,
    /// Remove the pinned host key for the target (unpair) and exit.
    forget_host: bool,
    /// Print this viewer's key fingerprint and exit.
    identity: bool,
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
    /// Use this saved connection (id, name or address) and make it the active one.
    connection: Option<String>,
    /// Print the saved connections and exit.
    list_connections: bool,
    /// Started by Windows at sign-in (the Run value): open paused unless config
    /// `connect_at_signin` (see `signin`).
    startup: bool,
}

const USAGE: &str = "usage: glide-client [host[:port] [--no-listen] | --listen [PORT] | --connection NAME] [options...]

  (no target)        use the config file: dial its \"host\" if set (and listen, see below), else
                     listen on its \"listen_port\" (default 7420). Opens the setup dialog when
                     nothing is set up yet, or when run from outside the install folder
  host[:port]        dial a Glide host (default port 7420) and also listen on 7420 (or
                     --listen PORT), so the Mac can connect when the network only allows Mac -> PC;
                     one connection at a time (config \"accept_incoming\")
  --no-listen        with a host: dial only
  --listen [PORT]    reverse connect: listen on 0.0.0.0:PORT (default 7420) and let the host
                     dial in (glide-host --connect); same protocol
  --connection NAME  use a saved connection (name, id or address; see the Connections window)
                     and make it the default for later launches too
  --list-connections print the saved connections and exit
  --setup            open the setup dialog (Mac address, firewall, start at sign-in, install)
  --startup          what the sign-in entry passes: open the window without connecting (until
                     Connect) unless config \"connect_at_signin\" is true
  --mode M           fast = 4:2:0 only; sharp = 4:4:4 every frame; hybrid = 4:2:0 while moving +
                     4:4:4 refinement at rest. Default: config, else hybrid if this PC decodes
                     HEVC 4:4:4, else fast
  --no-ctrl-as-cmd   don't map Ctrl->Cmd / Win->Control (also --ctrl-as-cmd to force it on)
  --no-clipboard     don't sync the clipboard (text + images) with the host (config: \"clipboard\")
  --forget-host      unpair: forget the host key pinned for the target, then exit (the next
                     connection pairs again; the Mac must be in \"Pair New Viewer…\" mode)
  --identity         print this viewer's key fingerprint (shown on the Mac while pairing) and exit
  --version          print the version and protocol version, then exit
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

Config: %APPDATA%\\Glide\\config.json (GLIDE_CONFIG_DIR overrides the folder). Pairing: the
first connection to a host shows a 6-digit code on both screens; confirm on both if they match.
The viewer's key is identity.dpapi next to the config (only this Windows account can use it).
Builds with the `test-hooks` feature only: GLIDE_PAIR_CONFIRM=yes|no answers the pairing prompt
non-interactively (tests, --bench); release builds ignore it (pipe `y` into --bench instead).

Viewer hotkeys (handled locally, never sent to the Mac; F11 / Alt+Enter also toggle fullscreen):";

fn parse_args() -> Result<Args, String> {
    parse_args_from(std::env::args().skip(1))
}

fn parse_args_from(args: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = args.into_iter().peekable();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--password" => {
                // v1 option: accepted (old launchers) but ignored.
                let _ = it.next();
                eprintln!("note: --password is ignored: Glide v2 pairs keys instead of using a password");
            }
            "--mode" => {
                let v = it.next().unwrap_or_default();
                a.mode = Some(config::mode_from_str(&v).ok_or("--mode must be fast, sharp or hybrid")?);
            }
            "--no-ctrl-as-cmd" => a.ctrl_as_cmd = Some(false),
            "--ctrl-as-cmd" => a.ctrl_as_cmd = Some(true),
            "--forget-host" => a.forget_host = true,
            "--identity" => a.identity = true,
            "--no-clipboard" => a.clipboard = Some(false),
            "--clipboard-selftest" => a.clipboard_selftest = true,
            "--clipboard-sync-secrets" => a.clipboard_sync_secrets = true,
            "--bench" => {
                let v = it.next().ok_or("--bench needs SECONDS")?;
                a.bench = Some(v.parse::<f64>().map_err(|_| format!("bad --bench value {v}"))?);
            }
            "--probe" => a.probe = true,
            "--no-listen" => a.no_listen = true,
            "--setup" => a.setup = true,
            "--after-setup" => a.after_setup = true,
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
            "--connection" => a.connection = Some(it.next().filter(|v| !v.trim().is_empty()).ok_or("--connection needs NAME")?),
            "--list-connections" => a.list_connections = true,
            glide::signin::STARTUP_FLAG => a.startup = true,
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
    if a.connection.is_some() && (a.host.is_some() || a.listen.is_some()) {
        return Err("--connection picks the target: don't also give a host or --listen".into());
    }
    Ok(a)
}

/// `--connection`: make the saved connection matching `query` the active one (so it is also the
/// default for later launches). Returns its name; the error lists what is saved.
fn use_connection(c: &mut config::Config, query: &str) -> Result<String, String> {
    let Some(s) = connections::find(c, query) else {
        let names: Vec<String> = c.connections.iter().filter(|s| s.is_supported()).map(|s| format!("“{}”", s.name)).collect();
        return Err(if names.is_empty() {
            format!("no saved connection “{query}” (none saved yet: add one with Connections… in the Glide or tray menu)")
        } else {
            format!("no saved connection “{query}”; saved: {}", names.join(", "))
        });
    };
    let (id, name) = (s.id.clone(), s.name.clone());
    connections::activate(c, &id)?;
    Ok(name)
}

/// `--list-connections`: one line per saved connection, `*` marking the active one.
fn connections_text(c: &config::Config) -> String {
    if c.connections.is_empty() {
        return "no saved connections (add one with Connections… in the Glide or tray menu)\n".into();
    }
    let mut out = String::new();
    for s in &c.connections {
        let active = if c.active_connection.as_deref() == Some(s.id.as_str()) { '*' } else { ' ' };
        let mut notes = Vec::new();
        if let Some(g) = &s.group {
            notes.push(format!("group {g}"));
        }
        if !s.is_supported() {
            notes.push(format!("{} (not supported here)", s.platform));
        } else if s.pairing(c).is_some() {
            notes.push("paired".into());
        } else {
            notes.push("not paired".into());
        }
        out.push_str(&format!("{active} {:<4} {}  —  {}  ({})\n", s.id, s.name, s.address_label(), notes.join(", ")));
    }
    out
}

/// Console pairing prompt (headless --bench, non-Windows). GLIDE_PAIR_CONFIRM=yes|no answers it
/// in `test-hooks` builds.
struct ConsolePairing;

impl PairingUi for ConsolePairing {
    fn confirm(&self, p: &PairPrompt) -> bool {
        eprintln!("PAIRING with {} — code {}  (host key {}, this viewer {})", p.peer, p.code, p.host_fingerprint, p.viewer_fingerprint);
        if let Some(v) = glide::util::test_hook("GLIDE_PAIR_CONFIRM") {
            let yes = matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "y" | "yes");
            eprintln!("GLIDE_PAIR_CONFIRM={v}: {}", if yes { "codes match" } else { "declined" });
            return yes;
        }
        use std::io::Write;
        eprint!("Does the Mac show the same code? Confirm it there too. [y/N] ");
        let _ = std::io::stderr().flush();
        let mut s = String::new();
        let _ = std::io::stdin().read_line(&mut s);
        matches!(s.trim().to_ascii_lowercase().as_str(), "y" | "yes")
    }
}

fn client_name() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "glide-client".into())
}

fn main() -> ExitCode {
    // Physical pixels everywhere (monitor sizes for ClientHello/ViewSize, window, swap chain).
    #[cfg(windows)]
    glide::win::set_dpi_awareness();
    if std::env::args().skip(1).any(|a| a == "--version" || a == "-V") {
        println!("{}", glide::version::banner());
        return ExitCode::SUCCESS;
    }
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

    // Persistent settings.
    let (mut store, warnings) = Store::open(config::config_dir());
    for w in &warnings {
        eprintln!("warning: {w}");
    }
    let cfg_dir = store.dir.clone();
    for v in glide::util::ignored_test_hooks() {
        eprintln!("note: {v} is ignored (test hooks are only in builds with the test-hooks feature)");
    }
    #[cfg(windows)]
    if store.config.clipboard_sync_secrets {
        glide::win::clipboard::set_sync_secrets(true);
    }
    // v1 leftovers: left in place (a rollback to v1 still finds them) but no longer used.
    if cfg_dir.as_deref().is_some_and(|d| d.join(config::LEGACY_PASSWORD_FILE).exists()) {
        eprintln!("note: {} (v1 saved password) is no longer used; Glide v2 pairs keys. It is left in place for a rollback", config::LEGACY_PASSWORD_FILE);
    }
    if std::env::var_os("GLIDE_PASSWORD").is_some() {
        eprintln!("note: GLIDE_PASSWORD is ignored: Glide v2 pairs keys instead of using a password");
    }
    if args.list_connections {
        print!("{}", connections_text(&store.config));
        return ExitCode::SUCCESS;
    }
    // Before resolving the target, which reads the active connection through `host`.
    if let Some(q) = &args.connection {
        let mut res = Ok(String::new());
        store.update(|c| res = use_connection(c, q));
        match res {
            Ok(name) => eprintln!("using saved connection “{name}”"),
            Err(e) => {
                eprintln!("error: {e}");
                return ExitCode::from(2);
            }
        }
    }

    // Sign-in entries written before `--startup` existed get it (only ones that start this exe).
    #[cfg(windows)]
    if args.bench.is_none() && !args.forget_host && !args.identity {
        glide::win::setup::migrate_signin_entry();
    }
    #[allow(unused_mut)]
    let mut start_paused = glide::signin::start_paused(args.startup, store.config.connect_at_signin);
    if start_paused {
        eprintln!("started at sign-in: not connecting until Connect (config \"connect_at_signin\" turns this off)");
    }

    // Visual setup (GUI launches only): nothing set up yet, an exe outside the install folder,
    // or --setup. It may install and relaunch the installed copy (then this process exits).
    #[cfg(windows)]
    if args.bench.is_none() && !args.forget_host && !args.identity && !args.after_setup && (args.setup || (args.host.is_none() && args.listen.is_none() && args.connection.is_none())) {
        match glide::win::setup::at_startup(&mut store, args.setup) {
            glide::win::setup::Startup::Continue => {}
            // Clicking Connect in the setup dialog is the user asking to connect, sign-in or not.
            glide::win::setup::Startup::Connect => start_paused = false,
            glide::win::setup::Startup::Exit => return ExitCode::SUCCESS,
        }
    }
    let target = config::resolve_target(args.host.as_deref(), args.listen, args.no_listen, &store.config);
    let pin_target = config::pin_target(&target);
    // Saved connections carry their own pins; the listen-mode fallback only still applies to a
    // target that isn't one (a host on the command line).
    let pin_fallback = config::pin_fallback(&target).filter(|_| glide::connections::use_pin_fallback(&store.config, &pin_target));
    if args.forget_host {
        match store.forget_host(&pin_target) {
            Some(p) => eprintln!("forgot host key {} for {pin_target} ({})", p.key, p.name),
            None => eprintln!("no host key pinned for {pin_target}"),
        }
        return ExitCode::SUCCESS;
    }
    let identity = match glide::identity::load_or_create(cfg_dir.as_deref()) {
        Ok((id, how)) => {
            match how {
                glide::identity::Loaded::Created => eprintln!("created this viewer's key ({})", id.fingerprint()),
                glide::identity::Loaded::Ephemeral => eprintln!("warning: no config folder; using a temporary key (pairing won't be remembered)"),
                glide::identity::Loaded::Existing => {}
            }
            id
        }
        Err(e) => {
            eprintln!("error: {e}\n(move the file away to create a new key; the viewer must then be paired again)");
            return ExitCode::from(1);
        }
    };
    if args.identity {
        println!("{}", identity.fingerprint());
        return ExitCode::SUCCESS;
    }
    let host = match &target {
        TargetSpec::Connect(h) | TargetSpec::Both { host: h, .. } => h.clone(),
        TargetSpec::Listen(p) => format!("listen:{p}"),
    };
    #[cfg_attr(not(windows), allow(unused_variables))]
    let connect_label = glide::signin::connect_label(&store.config, args.host.is_some() || args.listen.is_some(), &host);
    let ctrl_as_cmd = args.ctrl_as_cmd.unwrap_or(store.config.ctrl_as_cmd);

    // Capabilities: HEVC 4:2:0 + H.264 always; HEVC 4:4:4 only if this machine can decode it.
    #[allow(unused_mut)]
    let mut caps = protocol::CAP_HEVC_420 | protocol::CAP_H264_420;
    #[cfg(windows)]
    {
        if glide::win::probe::hevc444_supported() {
            caps |= protocol::CAP_HEVC_444;
        }
        // Clipboard sync (§5) needs the viewer window; the headless bench never advertises it.
        // The GUI viewer drops the bit from each ClientHello while sync is switched off (menu).
        if args.bench.is_none() {
            caps |= protocol::CAP_CLIPBOARD;
        }
        // File transfer (§6): GUI viewer only (drag & drop, hotkeys, notifications).
        if store.config.file_transfer && args.bench.is_none() {
            caps |= protocol::CAP_FILES;
        }
        // Mac display picker (§3.5): GUI viewer only (menu, hotkeys, toasts).
        if args.bench.is_none() {
            caps |= protocol::CAP_DISPLAYS;
        }
        // Input extensions (§3.6): the GUI viewer.
        if args.bench.is_none() {
            caps |= protocol::CAP_INPUT_EXT;
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
                TargetSpec::Both { host, port } => Target::Both { addr: host, port },
            };
            let opts = Options {
                ctrl_as_cmd,
                mode,
                host_label: host,
                has444,
                audio: audio_on,
                audio_muted: store.config.audio_muted,
                latency_test: args.latency_test,
                clipboard: args.clipboard.unwrap_or(store.config.clipboard),
                start_paused,
                connect_label,
                store,
            };
            return match glide::win::app::run(Connector { target, identity, pin_target, pin_fallback, hello }, opts) {
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

    // Bench: one-shot connection (pairing on the console if needed).
    let _ = ctrl_as_cmd;
    let auth = Auth {
        identity,
        name: client_name(),
        target: pin_target.clone(),
        pinned: store.config.pinned_key_or(&pin_target, pin_fallback.as_deref()),
        request_pairing: false,
        pairing: Arc::new(ConsolePairing),
        // One-shot --bench --listen: started by hand for this connection, and the console asks.
        inbound_pairing: Arc::new(|| true),
    };
    // One-shot: dial (both mode doesn't wait for the host to dial in here).
    let res = match &target {
        TargetSpec::Listen(port) => Connection::listen(*port, &auth, &hello),
        TargetSpec::Connect(h) | TargetSpec::Both { host: h, .. } => Connection::connect(h, &auth, &hello),
    };
    let conn = match res {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: connect to {host}: {}", e.user_message(&host));
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
    if conn.paired {
        store.pin_host(&pin_target, &conn.host_key, &conn.host_name);
    }
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
        assert_eq!(a.listen, Some(7421), "v1 --password is accepted and ignored");
        assert!(p(&["--identity"]).unwrap().identity);
        let a = p(&["mac.local:7420", "--ctrl-as-cmd", "--forget-host", "--no-clipboard", "--no-audio"]).unwrap();
        assert_eq!(a.clipboard, Some(false));
        assert_eq!(a.audio, Some(false));
        assert_eq!(p(&["--audio-selftest"]).unwrap().audio_selftest, Some(3.0));
        assert_eq!(p(&["--audio-selftest", "5"]).unwrap().audio_selftest, Some(5.0));
        assert_eq!(a.host.as_deref(), Some("mac.local:7420"));
        assert_eq!(a.ctrl_as_cmd, Some(true));
        assert!(a.forget_host);
        assert!(p(&["--mode", "ultra"]).is_err());
        assert!(p(&["a", "b"]).is_err());
        assert!(p(&["--nope"]).is_err());
        assert_eq!(p(&["--help"]), Err(String::new()));
    }

    #[test]
    fn cli_overrides_config() {
        let mut c = config::Config { host: Some("cfg-host".into()), ..config::Config::default() };
        c.set_mode(Mode::Fast);
        let a = p(&["--listen", "--mode", "hybrid"]).unwrap();
        assert_eq!(config::resolve_target(a.host.as_deref(), a.listen, a.no_listen, &c), TargetSpec::Listen(7420));
        assert_eq!(config::resolve_mode(a.mode, &c, true).0, Mode::Hybrid);
        let a = p(&[]).unwrap();
        assert_eq!(config::resolve_target(a.host.as_deref(), a.listen, a.no_listen, &c), TargetSpec::Both { host: "cfg-host".into(), port: 7420 });
        let a = p(&["mac", "--no-listen"]).unwrap();
        assert!(a.no_listen);
        assert_eq!(config::resolve_target(a.host.as_deref(), a.listen, a.no_listen, &c), TargetSpec::Connect("mac".into()));
        assert!(p(&["--setup"]).unwrap().setup);
        assert_eq!(config::resolve_mode(a.mode, &c, true).0, Mode::Fast);
        assert!(a.ctrl_as_cmd.unwrap_or(c.ctrl_as_cmd));
    }

    #[test]
    fn connection_args() {
        let a = p(&["--connection", "Studio Mac", "--mode", "fast"]).unwrap();
        assert_eq!(a.connection.as_deref(), Some("Studio Mac"));
        assert!(p(&["--connection", "x", "--no-listen"]).is_ok(), "dial only still applies");
        assert!(p(&["--connection"]).is_err());
        assert!(p(&["--connection", " "]).is_err());
        assert!(p(&["--connection", "x", "mac.local"]).is_err(), "two targets");
        assert!(p(&["mac.local", "--connection", "x"]).is_err());
        assert!(p(&["--connection", "x", "--listen"]).is_err());
        assert!(p(&["--list-connections"]).unwrap().list_connections);
    }

    #[test]
    fn startup_flag() {
        assert!(!p(&[]).unwrap().startup);
        let a = p(&["--startup"]).unwrap();
        assert!(a.startup && a.host.is_none());
        // An old install.ps1 shortcut put the Mac's address in front of it.
        let a = p(&["192.168.1.50", "--startup"]).unwrap();
        assert!(a.startup);
        assert_eq!(a.host.as_deref(), Some("192.168.1.50"));
        // What the Run value passes is exactly what the parser takes.
        let v = glide::setup::run_value(std::path::Path::new("C:\\x\\glide-client.exe"));
        let (_, rest) = glide::signin::split_run_value(&v).unwrap();
        assert!(p(&rest.split_whitespace().collect::<Vec<_>>()).unwrap().startup);
    }

    #[test]
    fn use_connection_activates_and_lists() {
        use glide::connections::{add, Draft};
        let mut c = config::Config::default();
        assert!(use_connection(&mut c, "x").unwrap_err().contains("none saved yet"));
        assert!(connections_text(&c).starts_with("no saved connections"));
        let d = |name: &str, addr: &str| Draft { name: name.into(), address: addr.into(), ..Draft::new_default() };
        let studio = add(&mut c, &d("Studio Mac", "192.168.1.20")).unwrap();
        let laptop = add(&mut c, &Draft { group: "Home".into(), accept_incoming: false, ..d("Laptop", "10.0.0.5:7421") }).unwrap();
        assert_eq!(c.active_connection.as_deref(), Some(studio.as_str()), "the first one added is active");
        // By name (any case), then the target follows it.
        assert_eq!(use_connection(&mut c, "laptop").unwrap(), "Laptop");
        assert_eq!(c.active_connection.as_deref(), Some(laptop.as_str()));
        assert_eq!(config::resolve_target(None, None, false, &c), TargetSpec::Connect("10.0.0.5:7421".into()));
        // By address and by id.
        assert_eq!(use_connection(&mut c, "192.168.1.20").unwrap(), "Studio Mac");
        assert_eq!(config::resolve_target(None, None, false, &c), TargetSpec::Both { host: "192.168.1.20".into(), port: 7420 });
        assert_eq!(use_connection(&mut c, &laptop).unwrap(), "Laptop");
        let e = use_connection(&mut c, "nope").unwrap_err();
        assert!(e.contains("“Studio Mac”") && e.contains("“Laptop”"), "{e}");
        let text = connections_text(&c);
        assert!(text.contains("  c1   Studio Mac  —  192.168.1.20  (not paired)"), "{text}");
        assert!(text.contains("* c2   Laptop  —  10.0.0.5:7421  (group Home, not paired)"), "{text}");
    }

}
