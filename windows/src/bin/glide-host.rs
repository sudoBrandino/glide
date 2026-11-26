//! glide-host: the Windows host — lets a Mac (glide-viewer) control this PC (docs/WINDOWS_HOST.md).
//!
//! Usage: glide-host [--port N] [--bind ADDR] [--pair] [--name NAME] [--bitrate KBPS] [--test-mode]
//!        glide-host --paired | --unpair NAME|KEY | --identity | --version
//! Listens on TCP 7421. Tray menu: Pair New Mac…, Paired Macs, Quit. Console commands while
//! running: `pair`, `paired`, `unpair NAME|KEY`, `quit`; while a
//! pairing is waiting, type the 6-digit code shown on the Mac (or `no`) if no dialog appeared.

use glide::host::auth::{serve, Authed, HostCtx, LocalConfirm, PairRequest};
use glide::host::stream::{run_test_session, SessionSlot};
use glide::host::trust::{config_dir, load_or_create_identity, HostConfig, TrustStore, CONFIG_FILE, PAIRING_WINDOW};
use glide::host::{log, DEFAULT_PORT};
use std::io::BufRead;
use std::net::TcpListener;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const USAGE: &str = "usage: glide-host [options]

Lets a Mac running Glide Viewer see and control this PC.

  --port N          TCP port to listen on (default 7421; host.json \"port\")
  --bind ADDR       address to listen on (default all: 0.0.0.0 and [::]; host.json \"bind\")
  --pair            open the pairing window for 2 minutes at start (also: type `pair`)
  --name NAME       name shown on the Mac (default: the computer name; host.json \"name\")
  --bitrate KBPS    fixed video bitrate (default: automatic, ~30 Mbps at 1440p)
  --test-mode       handshake and ServerHello only: no screen capture, no input (diagnostics)
  --paired          list paired Macs and exit
  --unpair NAME|KEY remove a paired Mac (by name or 64-hex key) and exit
  --identity        print this PC's key fingerprint and exit
  --version         print the version and exit

Files: %APPDATA%\\Glide\\host.json (paired viewers, port), %APPDATA%\\Glide\\host-identity.dpapi
(this PC's key, DPAPI-protected). GLIDE_CONFIG_DIR overrides the folder.
Tray icon: Pair New Mac…, Paired Macs ▸ Remove…, Open config file, Quit.
Console commands while running: pair, paired, unpair NAME|KEY, quit.";

#[derive(Debug, Default, PartialEq)]
struct Args {
    port: Option<u16>,
    bind: Option<String>,
    pair: bool,
    name: Option<String>,
    bitrate: Option<u32>,
    test_mode: bool,
    paired: bool,
    unpair: Option<String>,
    identity: bool,
    version: bool,
}

fn parse(argv: &[String]) -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = argv.iter();
    while let Some(s) = it.next() {
        let mut val = |name: &str| it.next().cloned().ok_or_else(|| format!("{name} needs a value"));
        match s.as_str() {
            "--port" => a.port = Some(val("--port")?.parse().map_err(|_| "bad --port".to_string())?),
            "--bind" => a.bind = Some(val("--bind")?),
            "--pair" => a.pair = true,
            "--name" => a.name = Some(val("--name")?),
            "--bitrate" => a.bitrate = Some(val("--bitrate")?.parse().map_err(|_| "bad --bitrate".to_string())?),
            "--test-mode" => a.test_mode = true,
            "--paired" => a.paired = true,
            "--unpair" => a.unpair = Some(val("--unpair")?),
            "--identity" => a.identity = true,
            "--version" | "-V" => a.version = true,
            "--help" | "-h" | "/?" => return Err(String::new()),
            x => return Err(format!("unknown argument {x}")),
        }
    }
    Ok(a)
}

/// Pairing confirmation on the console: the user types the code the Mac shows (or "no").
#[derive(Default)]
struct ConsoleConfirm {
    pending: Mutex<Option<(String, mpsc::Sender<bool>)>>,
}

impl ConsoleConfirm {
    /// A console line while a pairing waits. Returns true if it was consumed as the answer.
    fn answer(&self, line: &str) -> bool {
        let mut g = self.pending.lock().unwrap();
        let Some((code, tx)) = g.as_ref() else { return false };
        let typed: String = line.chars().filter(|c| c.is_ascii_digit()).collect();
        let want: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
        let ok = if line.trim().eq_ignore_ascii_case("no") {
            false
        } else if typed.len() == 6 {
            if typed != want {
                eprintln!("The code doesn't match: declining.");
            }
            typed == want
        } else {
            return false;
        };
        let _ = tx.send(ok);
        *g = None;
        true
    }
}

impl LocalConfirm for ConsoleConfirm {
    fn confirm(&self, req: &PairRequest, cancel: Arc<AtomicBool>) -> bool {
        let (tx, rx) = mpsc::channel();
        *self.pending.lock().unwrap() = Some((req.code.clone(), tx));
        eprintln!(
            "\nPairing request from “{}” at {}\n  Mac key: {}\n  This PC: {}\nType the 6-digit code the Mac shows to allow it, or `no`:",
            req.viewer_name, req.peer, req.viewer_fingerprint, req.host_fingerprint
        );
        let r = loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(v) => break v,
                Err(mpsc::RecvTimeoutError::Timeout) if !cancel.load(Ordering::SeqCst) => {}
                Err(_) => break false,
            }
        };
        *self.pending.lock().unwrap() = None;
        r
    }
}

fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}

/// The LAN listeners. Managed mode can turn LAN mode off (and on again) at runtime: then the host
/// stops listening altogether (docs/ENTERPRISE.md §7), not just refusing connections.
struct Lan {
    addrs: Vec<String>,
    explicit_bind: bool,
    /// Local addresses of the running listeners (empty = not listening).
    bound: Mutex<Vec<std::net::SocketAddr>>,
    ctx: Arc<HostCtx>,
    on_authed: Arc<dyn Fn(Authed) + Send + Sync>,
}

impl Lan {
    /// Binds and serves every address (once). Returns what it listens on.
    fn start(&self) -> Result<Vec<String>, String> {
        let mut bound = self.bound.lock().unwrap();
        if !bound.is_empty() {
            return Ok(Vec::new());
        }
        let mut listeners = Vec::new();
        let mut names = Vec::new();
        for a in &self.addrs {
            match TcpListener::bind(a) {
                Ok(l) => {
                    listeners.push(l);
                    names.push(a.clone());
                }
                // [::] may share 0.0.0.0's port (dual-stack) or IPv6 may be off: not fatal.
                Err(e) if !self.explicit_bind && a.starts_with('[') => log(&format!("not listening on {a}: {e}")),
                Err(e) => return Err(format!("cannot listen on {a}: {e}")),
            }
        }
        for l in listeners {
            if let Ok(a) = l.local_addr() {
                bound.push(a);
            }
            let (ctx, on_authed) = (self.ctx.clone(), self.on_authed.clone());
            std::thread::spawn(move || {
                if let Err(e) = serve(l, ctx, on_authed) {
                    log(&format!("listener stopped: {e}"));
                }
            });
        }
        Ok(names)
    }

    /// Stops listening: `serve` returns at its next accept once LAN mode is off, so wake it.
    fn stop(&self) {
        let bound: Vec<_> = self.bound.lock().unwrap().drain(..).collect();
        for mut a in bound {
            if a.ip().is_unspecified() {
                a.set_ip(if a.is_ipv4() { std::net::Ipv4Addr::LOCALHOST.into() } else { std::net::Ipv6Addr::LOCALHOST.into() });
            }
            let _ = std::net::TcpStream::connect_timeout(&a, Duration::from_secs(1));
        }
    }

    /// Listen exactly while LAN mode is allowed.
    fn sync(&self) {
        if self.ctx.lan_allowed() {
            match self.start() {
                Ok(n) if !n.is_empty() => log(&format!("LAN connections are on: listening on {}", n.join(", "))),
                Ok(_) => {}
                Err(e) => log(&format!("LAN connections: {e}")),
            }
        } else {
            let was = !self.bound.lock().unwrap().is_empty();
            self.stop();
            if was {
                log("LAN connections are off: stopped listening");
            }
        }
    }
}

/// Managed-mode prompt where there is no dialog (non-Windows builds): every request needing
/// approval is declined.
#[cfg(not(windows))]
struct NoPrompt;

#[cfg(not(windows))]
impl glide::cloud::host::HostUi for NoPrompt {
    fn approve(&self, _o: &glide::cloud::api::SessionOffer, _cancel: Arc<AtomicBool>) -> glide::cloud::host::Approval {
        glide::cloud::host::Approval::Decline
    }
}

fn default_name() -> String {
    #[cfg(windows)]
    {
        glide::host::win::computer_name()
    }
    #[cfg(not(windows))]
    {
        std::env::var("HOSTNAME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "glide-host".into())
    }
}

fn print_paired(list: &[glide::host::trust::PairedViewer]) {
    if list.is_empty() {
        println!("No paired Macs. Run `glide-host --pair` and connect from the Mac.");
    }
    for v in list {
        println!("{}  {}  paired {}  key {}", v.name, v.fingerprint(), v.paired, v.key);
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = match parse(&argv) {
        Ok(a) => a,
        Err(e) => {
            if !e.is_empty() {
                eprintln!("glide-host: {e}\n");
            }
            eprintln!("{USAGE}");
            return if e.is_empty() { ExitCode::SUCCESS } else { ExitCode::from(2) };
        }
    };
    if args.version {
        println!("glide-host {} (protocol v{})", env!("CARGO_PKG_VERSION"), glide::protocol::PROTOCOL_VERSION);
        return ExitCode::SUCCESS;
    }
    let Some(dir) = config_dir() else {
        eprintln!("glide-host: no configuration folder (%APPDATA% not set; set GLIDE_CONFIG_DIR)");
        return ExitCode::FAILURE;
    };
    let cfg_path = dir.join(CONFIG_FILE);
    let cfg = match HostConfig::load(&cfg_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("glide-host: {e} (fix or delete the file)");
            return ExitCode::FAILURE;
        }
    };
    if args.paired {
        print_paired(&cfg.paired_viewers);
        return ExitCode::SUCCESS;
    }
    if let Some(what) = &args.unpair {
        // Locked read-modify-write: a running glide-host may be pairing at the same time.
        let removed = match TrustStore::new(Some(cfg_path.clone()), cfg).remove(what) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("glide-host: {e}");
                return ExitCode::FAILURE;
            }
        };
        if removed.is_empty() {
            eprintln!("glide-host: no paired Mac named or keyed {what:?}");
            return ExitCode::FAILURE;
        }
        for v in removed {
            println!("Removed {} ({}). A running glide-host ends its session within 2 s.", v.name, v.fingerprint());
        }
        return ExitCode::SUCCESS;
    }
    let identity = match load_or_create_identity(&dir) {
        Ok((id, created)) => {
            if created {
                log(&format!("created this PC's key in {}", dir.display()));
            }
            id
        }
        Err(e) => {
            eprintln!("glide-host: {e}");
            return ExitCode::FAILURE;
        }
    };
    if args.identity {
        println!("{}", identity.fingerprint());
        return ExitCode::SUCCESS;
    }

    #[cfg(windows)]
    glide::host::win::set_dpi_awareness();
    let port = args.port.or(cfg.port).unwrap_or(DEFAULT_PORT);
    let bind = args.bind.clone().or(cfg.bind.clone());
    let host_name = args.name.clone().or(cfg.name.clone()).unwrap_or_else(default_name);
    let console = Arc::new(ConsoleConfirm::default());
    #[cfg(windows)]
    let confirm: Arc<dyn LocalConfirm> = Arc::new(glide::host::win::confirm::DialogConfirm { fallback: console.clone() });
    #[cfg(not(windows))]
    let confirm: Arc<dyn LocalConfirm> = console.clone();
    let fp = identity.fingerprint();
    let ctx = Arc::new(HostCtx::new(identity, TrustStore::new(Some(cfg_path.clone()), cfg), confirm));

    let addrs: Vec<String> = match &bind {
        Some(b) if b.contains(':') && !b.starts_with('[') => vec![format!("[{b}]:{port}")],
        Some(b) => vec![format!("{b}:{port}")],
        None => vec![format!("0.0.0.0:{port}"), format!("[::]:{port}")],
    };
    // Managed mode (Glide Cloud, docs/ENTERPRISE.md): the organization's policy, if any.
    let (managed, policy_read) = match glide::cloud::managed::load() {
        Ok(m) => (m, true),
        Err(e) => {
            log(&format!("managed configuration ignored: {e}"));
            (None, false)
        }
    };
    if policy_read && !managed.as_ref().is_some_and(|m| m.has_cloud()) {
        // No CloudURL (any more): a revocation record from an earlier one stops applying (§6.7).
        use glide::cloud::{enroll, store};
        store::Store::new(&dir, enroll::Kind::Host.file(), store::platform_seal()).forget_revoked();
    }
    if managed.as_ref().is_some_and(|m| m.disable_lan_mode) {
        ctx.set_policy(false, false);
        log("LAN connections are turned off by policy (DisableLANMode)");
    }
    log(&format!("config: {}", cfg_path.display()));
    if args.test_mode {
        log("TEST MODE: no screen capture and no input injection");
    }

    let slot = Arc::new(SessionSlot::default());
    #[cfg(windows)]
    let opts = Arc::new(glide::host::win::session::SessionOpts { host_name: host_name.clone(), bitrate_kbps: args.bitrate });
    // Runs one authenticated session (LAN or managed) in the slot. `authorized` is asked every
    // 2 s while it streams.
    let run_session: Arc<dyn Fn(Authed, Box<dyn Fn() -> bool + Send>) + Send + Sync> = {
        let (slot, test_mode, host_name) = (slot.clone(), args.test_mode, host_name.clone());
        #[cfg(windows)]
        let opts = opts.clone();
        Arc::new(move |a: Authed, authorized: Box<dyn Fn() -> bool + Send>| {
            let id = a.conn_id;
            let stop = slot.enter(id, Duration::from_secs(10));
            if test_mode {
                let _ = &authorized;
                run_test_session(a, &host_name, stop);
            } else {
                #[cfg(windows)]
                glide::host::win::session::run(a, &opts, &*authorized, stop);
                #[cfg(not(windows))]
                {
                    let _ = &authorized;
                    log("screen capture is only implemented on Windows; running as --test-mode");
                    run_test_session(a, &host_name, stop);
                }
            }
            slot.leave(id);
        })
    };
    let on_authed: Arc<dyn Fn(Authed) + Send + Sync> = {
        let (ctx, run_session) = (ctx.clone(), run_session.clone());
        Arc::new(move |a: Authed| {
            let (ctx2, key) = (ctx.clone(), a.viewer_key);
            run_session(a, Box::new(move || ctx2.trust.is_paired(&key) && ctx2.lan_allowed()));
        })
    };
    let lan = Arc::new(Lan { addrs: addrs.clone(), explicit_bind: bind.is_some(), bound: Mutex::new(Vec::new()), ctx: ctx.clone(), on_authed: on_authed.clone() });

    // Managed mode: enroll, hub, approval prompts, relayed sessions.
    let local_disable = managed.as_ref().is_some_and(|m| m.disable_lan_mode);
    let cloud = match (managed.filter(|m| m.has_cloud()), glide::cloud::platform_http()) {
        (Some(m), Some(http)) => {
            use glide::cloud::{enroll, host as chost, settings, store};
            let facts = enroll::DeviceFacts {
                kind: enroll::Kind::Host,
                public_key: ctx.identity.public(),
                name: m.device_name.clone().unwrap_or_else(|| host_name.clone()),
                os_version: glide::cloud::os_version(),
                app_version: settings::app_version().into(),
            };
            log(&format!("managed by Glide Cloud at {}", m.cloud_url));
            let st = store::Store::new(&dir, enroll::Kind::Host.file(), store::platform_seal());
            #[cfg(windows)]
            let ui: Arc<dyn chost::HostUi> = Arc::new(glide::host::win::confirm::CloudPrompt);
            #[cfg(not(windows))]
            let ui: Arc<dyn chost::HostUi> = Arc::new(NoPrompt);
            let hooks = chost::HostHooks {
                busy: Box::new({
                    let slot = slot.clone();
                    move || slot.busy()
                }),
                run_session: Box::new({
                    let (ctx, run_session) = (ctx.clone(), run_session.clone());
                    // A handshake failure is logged and reported as client.error by the agent.
                    move |stream, active: Arc<chost::ActiveSession>| {
                        let a = glide::host::auth::accept_relay(stream, &active.session_id, &ctx).map_err(|e| e.to_string())?;
                        log(&format!("managed session {}: {}", active.session_id, active.label()));
                        active.authenticated();
                        let live = active.clone();
                        run_session(a, Box::new(move || live.live()));
                        Ok(())
                    }
                }),
                settings: Box::new({
                    let (ctx, lan) = (ctx.clone(), lan.clone());
                    move |s: &glide::cloud::Settings| {
                        let (l, p) = (settings::lan_allowed(Some(s), local_disable), settings::local_pairing_allowed(Some(s), local_disable));
                        if l != ctx.lan_allowed() || p != ctx.local_pairing_allowed() {
                            log(&format!("organization settings: LAN connections {}, local pairing {}", on_off(l), on_off(p)));
                        }
                        ctx.set_policy(l, p);
                        lan.sync();
                    }
                }),
            };
            Some(chost::start(m, st, http, facts, ctx.grants.clone(), ui, hooks))
        }
        (Some(_), None) => {
            log("managed mode needs Windows (WinHTTP); running unmanaged");
            None
        }
        _ => None,
    };

    if ctx.lan_allowed() {
        match lan.start() {
            Ok(bound) => log(&format!("glide-host {} “{host_name}” listening on {} (key {fp})", env!("CARGO_PKG_VERSION"), bound.join(", "))),
            Err(e) => {
                eprintln!("glide-host: {e}");
                return ExitCode::FAILURE;
            }
        }
        let paired = ctx.trust.list();
        if paired.is_empty() && !args.pair {
            log("no paired Mac yet: choose Pair New Mac… in the tray menu, type `pair` here (or start with --pair), then connect from the Mac");
        }
    } else {
        log(&format!("glide-host {} “{host_name}” (key {fp}): LAN connections are off; managed sessions only", env!("CARGO_PKG_VERSION")));
    }
    if args.pair && ctx.open_pairing(PAIRING_WINDOW) {
        log("pairing window open for 2 minutes");
    }
    #[cfg(windows)]
    {
        use glide::host::win::tray::{start, TrayActions};
        let (c1, c2, c3, c4, c5, slot2) = (ctx.clone(), ctx.clone(), ctx.clone(), ctx.clone(), ctx.clone(), slot.clone());
        let (k1, k2, k3, k4) = (cloud.clone(), cloud.clone(), cloud.clone(), cloud.clone());
        start(TrayActions {
            pair: Box::new(move || {
                if c1.open_pairing(PAIRING_WINDOW) {
                    log("pairing window open for 2 minutes (Pair New Mac…): connect from the Mac now");
                }
            }),
            pairing_allowed: Box::new(move || c5.local_pairing_allowed()),
            cloud_status: Box::new(move || k1.as_ref().map(|c| c.status())),
            cloud_session: Box::new(move || k2.as_ref().and_then(|c| c.active()).map(|a| a.label())),
            end_session: Box::new(move || {
                if let Some(c) = &k3 {
                    c.end_session();
                }
            }),
            pairing_left: Box::new(move || c2.window.remaining(std::time::Instant::now()).map(|d| d.as_secs())),
            paired: Box::new(move || c3.trust.list().into_iter().map(|v| (v.name.clone(), v.fingerprint(), v.key.clone())).collect()),
            unpair: Box::new(move |key| match c4.trust.remove(key) {
                Ok(r) => r.iter().for_each(|v| log(&format!("unpaired {} ({})", v.name, v.fingerprint()))),
                Err(e) => log(&format!("unpair failed: {e}")),
            }),
            config_path: cfg_path.clone(),
            quit: Box::new(move || {
                log("quitting");
                if let Some(c) = &k4 {
                    c.end_session();
                    c.stop();
                }
                slot2.stop_current();
                std::thread::sleep(Duration::from_millis(500));
                std::process::exit(0);
            }),
        });
    }

    // Console commands (and typed pairing codes).
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if console.answer(&line) {
            continue;
        }
        match line.trim().to_ascii_lowercase().as_str() {
            "" => {}
            "pair" => {
                if ctx.open_pairing(PAIRING_WINDOW) {
                    log("pairing window open for 2 minutes: connect from the Mac now");
                }
            }
            "end" => match cloud.as_ref().and_then(|c| c.active()) {
                Some(_) => cloud.as_ref().unwrap().end_session(),
                None => eprintln!("no managed session is running"),
            },
            "status" => match &cloud {
                Some(c) => {
                    println!("{}", c.status());
                    if let Some(a) = c.active() {
                        println!("{}", a.label());
                    }
                }
                None => println!("not managed (no Glide Cloud policy)"),
            },
            "paired" => print_paired(&ctx.trust.list()),
            x if x.starts_with("unpair ") => match ctx.trust.remove(line.trim()[7..].trim()) {
                Ok(r) if r.is_empty() => eprintln!("no paired Mac by that name or key"),
                Ok(r) => r.iter().for_each(|v| log(&format!("unpaired {} ({})", v.name, v.fingerprint()))),
                Err(e) => eprintln!("{e}"),
            },
            "quit" | "exit" => {
                if let Some(c) = &cloud {
                    c.end_session();
                    c.stop();
                }
                slot.stop_current();
                std::thread::sleep(Duration::from_millis(300));
                return ExitCode::SUCCESS;
            }
            other => eprintln!("unknown command {other:?} (pair, paired, unpair NAME|KEY, status, end, quit)"),
        }
    }
    // No console (stdin closed, e.g. started detached): keep serving.
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &[&str]) -> Result<Args, String> {
        parse(&s.iter().map(|x| x.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn args() {
        assert_eq!(p(&[]).unwrap(), Args::default());
        let a = p(&["--port", "7500", "--pair", "--bind", "192.168.1.5", "--bitrate", "20000", "--test-mode"]).unwrap();
        assert_eq!((a.port, a.pair, a.bind.as_deref(), a.bitrate, a.test_mode), (Some(7500), true, Some("192.168.1.5"), Some(20000), true));
        assert_eq!(p(&["--unpair", "MacBook"]).unwrap().unpair.as_deref(), Some("MacBook"));
        assert!(p(&["--port"]).is_err());
        assert!(p(&["--port", "x"]).is_err());
        assert!(p(&["--bogus"]).is_err());
        assert_eq!(p(&["--help"]), Err(String::new()));
    }

    #[test]
    fn console_code_entry() {
        let c = Arc::new(ConsoleConfirm::default());
        assert!(!c.answer("123456"), "nothing pending");
        let req = PairRequest {
            code: "123 456".into(),
            viewer_name: "m".into(),
            viewer_fingerprint: "a".into(),
            host_fingerprint: "b".into(),
            peer: "x".into(),
        };
        let c2 = c.clone();
        let h = std::thread::spawn(move || c2.confirm(&req, Arc::new(AtomicBool::new(false))));
        while c.pending.lock().unwrap().is_none() {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!c.answer("pair"), "not an answer");
        assert!(c.answer("123 456"));
        assert!(h.join().unwrap());
    }
}
