# Glide

[![CI](https://github.com/sudoBrandino/glide/actions/workflows/ci.yml/badge.svg)](https://github.com/sudoBrandino/glide/actions/workflows/ci.yml)

Glide is a remote desktop for controlling a Mac from a Windows PC, written from scratch. The goal
is Jump Desktop-level sharpness and responsiveness on a LAN, with both ends native:

- **Host (`mac/`, Swift):** ScreenCaptureKit capture, VideoToolbox hardware HEVC, and a
  ChaCha20-Poly1305 record layer over TCP. Input is injected with CGEvent, and cursor shapes are
  sent to the viewer.
- **Viewer (`windows/`, Rust):** Media Foundation hardware decode through D3D11, a flip-model
  swap chain, raw keyboard and mouse capture, and the host cursor shown as the native Windows
  cursor.

Its main difference from generic remote desktops is **hybrid mode**. While the screen changes,
Glide streams low-latency HEVC 4:2:0. Once the screen settles, it sends a 4:4:4 "sharp" refinement
layer, so text is pixel-exact at rest and motion stays fast.

| | |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Wire protocol (normative) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Pipelines, hybrid/canvas model, threading |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What's done and what's next |
| [`docs/LATENCY.md`](docs/LATENCY.md) | Latency breakdown, glass-to-glass test, tuning results |
| [`windows/README.md`](windows/README.md) | Viewer reference: all flags, env vars, headless modes |

## Architecture

```
 Mac host (glide-host, Swift)                                Windows viewer (glide-client.exe, Rust)
 ───────────────────────────────                              ──────────────────────────────────────
 ScreenCaptureKit ─┬─ 420v stream ─► TileDiff ─► VT HEVC 4:2:0 ─┐      ┌─► MF decoder #1 (base) ──┐
   (display)       │   (pixel diff → dirty rects, 16-px aligned)│      │                           ▼
                   └─ BGRA stream ─────────────► VT HEVC 4:4:4 ─┤      │                    RGB10A2 canvas ─► D3D11
                       (hybrid "sharp" layer, at rest)          │      │                    (scissored rect ▲  flip-model
 CursorMonitor ─► cursor shape / position ──────────────────────┤      ├─► MF decoder #2 (sharp)─┘   swap chain
                                                                ▼      │
                                          ChaCha20-Poly1305 records over TCP :7420
                                          (X25519 + password KDF handshake)
                                                                ▲      │
 CGEvent injector ◄── keys (USB HID) / mouse / wheel ───────────┘      └── raw input, Ctrl→Cmd remap, ViewSize
```

```mermaid
flowchart LR
  subgraph Mac["Mac host"]
    SCK[ScreenCaptureKit] --> E420[VideoToolbox<br/>HEVC 4:2:0 LL]
    SCK --> D[TileDiff<br/>patch rects]
    SCK --> E444[VideoToolbox<br/>HEVC 4:4:4 sharp]
    CUR[Cursor monitor]
    INJ[CGEvent injector]
  end
  NET(["TCP :7420<br/>ChaCha20-Poly1305"])
  subgraph PC["Windows viewer"]
    DB[MF decoder base] --> C[RGB canvas]
    DS[MF decoder sharp] --> C
    C --> SW[D3D11 swap chain]
    IN[Raw input + remap]
  end
  E420 --> NET
  D --> NET
  E444 --> NET
  CUR --> NET
  NET --> DB
  NET --> DS
  IN --> NET
  NET --> INJ
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the details.

## Status

| Feature | Status |
|---|---|
| Protocol v1 + reference crypto vectors (Python, Swift, Rust all agree) | done |
| HEVC 4:2:0 low-latency / 4:4:4 "sharp" / H.264 fallback | done |
| **Hybrid mode**: 4:2:0 while moving, 4:4:4 at rest, pixel-diff patch rects, color-matched layers | done |
| Latest-frame-wins scheduling, network backpressure, idle quality refresh | done |
| Keyboard (USB HID usages, Ctrl→Cmd remap, Win/Alt-Tab capture), mouse, wheel, cursor shapes | done |
| Viewer: borderless fullscreen, auto-reconnect, status overlay, dims last frame on disconnect | done |
| `ViewSize`: host re-captures to match the viewer's monitor (no resampling at 1:1) | done |
| Dial-out (host → viewer `--listen`) for one-way firewalls, auto-redial | done |
| Signed `Glide Host.app` + LaunchAgent (stable TCC grants), `host.json` config | done |
| Power management: no idle sleep while hosting, display kept awake during a session | done |
| CI: Swift build + selftest, Rust tests, Windows cross-build artifact, vector check | done |
| Clipboard sync (text + images, both directions) | done |
| Audio (SCK system audio → PCM → WASAPI, jitter buffer) | done (§3.2) |
| Viewer UX | in progress |
| Host UX: menu-bar item, automatic display mode, auth-gated session replacement | done |
| Security v2: PAKE + pinned host identity | next ([roadmap](docs/ROADMAP.md)) |
| Virtual display, UDP transport, multi-monitor, relay for WAN | planned |

## Performance

Measured on an M3 Pro host with an RTX 5070 Ti viewer.

**Encode time on the host:** hybrid mode, real desktop content.

| Output | Base layer (HEVC 4:2:0 low-latency) |
|---|---|
| 2560×1440 @ 60 Hz | ~10–12 ms |
| 3840×2160 @ 60 Hz | ~18 ms |

The 4:4:4 sharp IDR costs about 25–40 ms of encoder time at 4K. It is only sent once the screen
settles, and at most once per interval while small areas such as a clock or spinner keep changing.
The pixel diff runs in parallel with the hardware encode.

**Capture → decoded, same-Mac loopback (`glide-probe`), 2560×1440 @ 60 Hz:**

| Config | p50 / p95 |
|---|---|
| HEVC 4:2:0, low-latency RC, 1 frame in flight (default) | 14.8 / 21.9 ms |
| HEVC 4:2:0, normal RC | 12.4 / 37.5 ms |
| H.264 low-latency | 14.5 / 22.0 ms |
| HEVC 4:4:4 every frame ("sharp" mode) | 27.7 / 42.5 ms |
| any config, 2 frames in flight | +10–20 ms (queueing) |

Every frame now carries a per-stage latency breakdown, which shows up in the viewer HUD, the host
log and menu bar, and `--bench`. A block-code test pattern measures true glass-to-glass latency
(see [`docs/LATENCY.md`](docs/LATENCY.md)). The live LAN glass-to-glass run is still pending.
Offline, an idle-then-one-frame encode took about 20 ms because VideoToolbox paced itself by
wall-clock PTS gaps. With frame-counter PTS it takes about 11 ms, which is now the default.

## Install and run

### Requirements

- **Host:** macOS 14 or later on Apple silicon, which has hardware HEVC 4:4:4 encode. Building
  needs Swift 6, either from Xcode or the Command Line Tools.
- **Viewer:** Windows 10/11 with a GPU that hardware-decodes HEVC. The HEVC 4:4:4 decode needed
  for hybrid and sharp mode requires a recent NVIDIA or Intel GPU. HEVC decode on Windows also
  needs the "HEVC Video Extensions" from the Microsoft Store.
- **Building the viewer:** Rust stable. To cross-compile from the Mac, you also need MinGW-w64
  (`brew install mingw-w64`).

### Host (Mac)

```sh
# Build, sign and install "Glide Host.app" + a per-user LaunchAgent (starts at login, restarts on exit)
tools/make-host-app.sh && tools/install-host.sh
```

- `make-host-app.sh` signs the app with a stable identity, so macOS privacy grants survive
  rebuilds. Set `GLIDE_SIGN_ID="<identity>"` to choose the identity, or `GLIDE_SIGN_ID=-` for an
  ad-hoc signature. With an ad-hoc signature, grants may need to be renewed after each rebuild.
- `install-host.sh --no-start` installs without starting the app. `install-host.sh --uninstall`
  removes the app and the agent, but keeps the config.
- The log is written to `~/Library/Logs/glide-host.log`.

**Permissions.** The host needs **Screen Recording** to capture and **Accessibility** to inject
input. Grant both to *Glide Host*, not to Terminal:

```sh
~/Applications/Glide\ Host.app/Contents/MacOS/glide-host --request-permissions
```

This prompts for both permissions and waits until they are granted. A new Screen Recording grant
only takes effect after the host restarts. The LaunchAgent restarts it on its own, or you can run
`launchctl kickstart -k gui/$(id -u)/io.github.sudobrandino.glide.host`.

**Configuration** is stored in `~/Library/Application Support/Glide/host.json` (mode 0600):

| key | meaning |
|---|---|
| `salt` | Per-host password salt, generated on first run |
| `password` | Session password. If no password is configured anywhere, a random one is generated, printed once and saved here |
| `connect` | Default dial-out target (`HOST[:PORT]`). If it is set, the host dials the viewer instead of listening |
| `clipboard` | `{"syncConcealed": false}`. `true` also syncs password-manager (concealed) pasteboard items to the viewer |

```sh
H=~/Applications/Glide\ Host.app/Contents/MacOS/glide-host
"$H" --set-password-file /path/to/password   # store the password (use a long random one)
"$H" --set-connect 192.168.10.212:7420          # make the host dial this viewer by default
```

The password is resolved in this order: `--password`, then `--password-file`, then
`$GLIDE_PASSWORD`, then `host.json`. Other flags:

- `--port N` (default 7420)
- `--connect HOST[:PORT]`
- `--fps N` (default 60)
- `--bitrate-kbps N` (0 means automatic)
- `--max-width PX` (default 3840)
- `--display ID`

**For development**, without the app bundle:

```sh
cd mac && swift build -c release --build-system native   # native backend: needed with CLT-only setups
.build/release/glide-selftest ../docs/test-vectors.json  # protocol self-test
.build/release/glide-host --password-file ../.dev/password                      # listen
.build/release/glide-host --password-file ../.dev/password --connect 192.168.10.212  # dial out
# Local end-to-end check on the same Mac (exact latency); opens a small test window
.build/release/glide-probe 127.0.0.1 --password-file ../.dev/password --seconds 8 --animate --png /tmp/frame.png
```

Stop the LaunchAgent before you run a host from the shell (see Troubleshooting).

### Viewer (Windows)

To get the exe, either:

- download it from the `glide-client-windows-x64` artifact of a green
  [CI run](https://github.com/sudoBrandino/glide/actions/workflows/ci.yml), or
- cross-build it on the Mac:

```sh
cd windows
cargo test                                                 # platform-independent tests incl. vectors
cargo build --release --target x86_64-pc-windows-gnu       # → target/x86_64-pc-windows-gnu/release/glide-client.exe
```

The exe is self-contained: it uses static CRT and needs only system DLLs. Run it in the
interactive desktop session:

```bat
set GLIDE_PASSWORD=...
glide-client.exe --listen 7420        :: host dials in (glide-host --connect PC:7420)
glide-client.exe 192.168.50.4            :: or: viewer dials the host
```

- **F11** or **Alt+Enter** toggles borderless fullscreen.
- `--mode fast|sharp|hybrid` picks the mode. The default is `hybrid` when the GPU decodes HEVC
  4:4:4.
- `--no-ctrl-as-cmd` turns off the Ctrl→Cmd remap.
- The viewer keeps its window open across disconnects and reconnects on its own.

See [`windows/README.md`](windows/README.md) for every flag, `--probe`, `--bench` and the test
hooks.

## Host menu bar and display mode

`Glide Host.app` (built by `tools/make-host-app.sh`, installed as a LaunchAgent by
`tools/install-host.sh`) shows a menu-bar item: state icon (waiting / dialing / connected / paused /
problem), viewer name + IP, stream mode, resolution, fps / Mbps / encode ms, and actions (Disconnect,
Pause, Display Mode, Open Log, Copy Viewer Password, Restart, Quit Until Next Login — plain Quit
would just be relaunched by the agent's KeepAlive).

**Display mode** (`"display"` in `~/Library/Application Support/Glide/host.json`, or the menu):

| `mode` | picks (for the viewer's monitor size) |
|---|---|
| `automatic` (default) | `crisp` for normal viewers; for 4K-class viewers (≥ 3200×1800) `highDPIViewer`: `retina` (default, looks like 1920×1080) or `smooth` (looks like 2560×1440, downscaled) |
| `crisp` | non-HiDPI mode matching the viewer 1:1 (1440p viewer → 2560×1440 @1x) |
| `retina` | HiDPI mode whose pixels match the viewer 1:1 (4K → looks like 1920×1080) |
| `smooth` | HiDPI mode that looks like ≤ 2/3 of the viewer, downscaled to fit |
| `manual` | never touch the display mode |

Otherwise the largest mode ≤ the viewer's size (same aspect preferred) wins. Switches are applied
with `.forSession` scope before capture starts (mid-session: one re-capture → VideoConfig +
keyframe), and the previous mode is restored 10 s after the viewer disconnects
(`restoreOnDisconnect`, default true). Changing the mode yourself during a session pauses automatic
switching until the next session (and that mode is kept).

Only an authenticated viewer can replace the active session. Unauthenticated connections are
closed after 5 s without a valid ClientHello; at most 4 can be pending (2 per source IP), and a new
one evicts the oldest instead of being refused.

## Network model

Either side can open the TCP connection. Once it is open, the protocol is the same in both
directions, and the viewer always sends the first handshake message.

| Mode | Host | Viewer | Use when |
|---|---|---|---|
| **Viewer dials** (default) | `glide-host` listens on :7420 | `glide-client.exe MAC[:PORT]` | The PC can reach the Mac |
| **Host dials** | `glide-host --connect PC[:PORT]`, or `connect` set in `host.json` | `glide-client.exe --listen [PORT]` | Only Mac → PC connections are allowed |

When the host dials, it redials every 2 s while it is disconnected. In listen mode the viewer
accepts again after every disconnect.

**The admin-VLAN case.** In the reference setup, the Mac (192.168.50.4) is on an admin VLAN
(192.168.50.0/29). The UniFi zone firewall blocks Trusted → Admin, so the PC (192.168.10.212) can't reach
the Mac, but the Mac can reach the PC. The setup is:

- The host has `connect` set to `192.168.10.212:7420`.
- The viewer runs `--listen 7420`.
- A Windows Firewall rule on the PC admits only 192.168.50.4 to `glide-client.exe` at a fixed path.

Nothing listens on the Mac, and the PC accepts the connection only from the Mac.

## Security

- **Handshake:** ephemeral X25519, keys derived with HKDF from the shared secret and a
  PBKDF2-hashed password (100k iterations, per-host salt).
- **Record layer:** ChaCha20-Poly1305 with per-direction keys and counters. Any failure to decrypt
  closes the connection. The password itself is never sent.

**Known v1 limitation:** the password is mixed into the KDF, but there is no real PAKE and no
host identity. An active attacker who impersonates either side gets a value they can check
password guesses against offline.

Until Security v2 replaces this with CPace or SPAKE2 plus a pinned host key (see the
[roadmap](docs/ROADMAP.md)), mitigate it:

- Use a long random password, for example 16 characters.
- Keep Glide on a trusted LAN. Don't expose it to the internet.
- Prefer the host-dials setup with a firewall rule that admits only the Mac.

## Troubleshooting

- **Only one host can capture at a time.** A second `glide-host` interrupts the first one's
  ScreenCaptureKit stream. Before you run a host from the shell, stop the agent with
  `launchctl bootout gui/$(id -u)/io.github.sudobrandino.glide.host`. Bring it back with
  `tools/install-host.sh`. Running `glide-probe` against the live host also takes over the active
  session.
- **Black screen or "capture unavailable" in the log.** The display is asleep, locked or being
  reconfigured. The host keeps the session open, wakes the display and retries every 2 s. Mouse
  and keyboard input also wake it. While the host runs, it prevents idle *system* sleep. While a
  viewer is connected, it also prevents *display* sleep.
- **"Screen recording NOT granted" or no input.** Run `--request-permissions` from the app
  bundle, as shown above, and restart the agent. Grants belong to the signing identity, so
  rebuilding with a different identity loses them.
- **Blurry picture.** Glide never upscales: it captures at most the viewer monitor's physical
  width and tells the host whenever that changes (`ViewSize`). Pick the Mac display mode so the
  captured size equals the viewer monitor:
  - **1440p monitor:** native 2560×1440 at 1x ("crisp") is the sharpest. "Looks like 2560×1440"
    HiDPI renders at 5120×2880 and gets downscaled, which is smoother but softer.
  - **4K monitor:** "looks like 1920×1080" HiDPI is true Retina at 1:1.
  - **NVIDIA DSR/DLDSR:** with DSR on, Windows reports the DSR desktop size (for example
    3072×1728), so the host captures at that size and the GPU scales it down again. Turn DSR off
    for the Glide monitor, or pin the reported size with `GLIDE_VIEW=2560x1440`.
  - Keep Windows display scaling for the viewer monitor at whatever you like. The viewer is
    DPI-aware and draws video 1:1 whenever it fits.
- **Switching HiDPI modes from the command line.** `tools/display-mode.swift` lists and sets
  display modes, including the HiDPI duplicates that System Settings hides:

  ```sh
  swiftc -O tools/display-mode.swift -o ~/bin/glide-display-mode
  glide-display-mode                         # list modes (current first)
  glide-display-mode set 2560 1440 lodpi     # native 1x ("crisp")
  glide-display-mode set 2560 1440 hidpi     # "looks like 2560x1440" HiDPI ("smooth")
  glide-display-mode set 1920 1080 hidpi     # Retina 1:1 on a 4K monitor
  ```

  You can wrap these in a small `glide-res crisp|smooth|retina` script. The host notices the mode
  change and re-captures on its own.
- **Viewer says "Authentication failed".** The password differs between the two sides. Check the
  password resolution order above: a `GLIDE_PASSWORD` environment variable overrides `host.json`.
- **No hybrid or sharp mode.** The viewer advertises HEVC 4:4:4 only if its embedded 4:4:4 test
  clip decodes on the GPU at startup. Run `glide-client.exe --probe` to see why it doesn't.

## Development

- **Tests:**
  - `mac/`: `glide-selftest docs/test-vectors.json`.
  - `windows/`: `cargo test`, which covers the protocol codec, crypto against the vectors, HID
    table, Annex-B and networking helpers.
  - `tools/gen_vectors.py` is the independent Python reference and regenerates
    `docs/test-vectors.json`.
- **Testing the viewer without a Mac:** `tools/mock_host.py` streams files from
  `tools/make_streams.sh` (see `windows/README.md`).
- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request:
  - the Mac release build and selftest;
  - `cargo test` on Linux plus the MinGW cross-build, uploaded as an artifact;
  - a native MSVC build and test run on Windows, with a `--probe` smoke test;
  - the vector regeneration check.

Private project — all rights reserved.
