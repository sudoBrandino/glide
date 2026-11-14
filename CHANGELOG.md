# Changelog

All notable changes to Glide are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Glide uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a minor
release may change the wire protocol or the config files; such changes are called out here.

Each release lists the wire protocol version it speaks (`docs/PROTOCOL.md`). The host and the
viewer must speak the same protocol version.

<!--
Add entries under [Unreleased] as part of each pull request, in the matching subsection
(Added, Changed, Deprecated, Removed, Fixed, Security). Write for testers and users: say what
changed for them, not how. Delete empty subsections when the release is cut.
-->

## [Unreleased]

### Added

- **Guided installers.** On the Mac,
  `curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/main/install.sh | bash`
  downloads the latest release, checks it against `SHA256SUMS`, installs the app and its
  LaunchAgent, replaces an older Glide Host that would compete for the screen, walks through
  Screen Recording and Accessibility (clearing grants left over from a previous version), asks
  which side connects and opens the pairing window. On Windows,
  `irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1 | iex` does the same
  for the viewer: it installs it where an existing viewer lives, so firewall rules keep applying,
  offers a firewall rule and Start menu and sign-in shortcuts. Run either again to update or to
  change the connection. Both have `--uninstall` / `-Uninstall`.
- **Homebrew:** `brew install --cask sudobrandino/glide/glide-host`, then `glide-setup` (the same
  installer, shipped inside the app); run `glide-setup` again after `brew upgrade`.
- `glide-host --permission-status` reports whether Screen Recording and Accessibility are granted,
  without prompting. The installer uses it to notice the grants as soon as you make them.

### Changed

- The LaunchAgent keeps the host running only while the app exists (`KeepAlive` `PathState`):
  deleting the app no longer leaves launchd retrying in the background. Run the installer once
  to switch an existing install over.
- `tools/install-host.sh` is now a thin wrapper around `install.sh`.

## [0.2.0] - 2026-11-14

The first public release. Protocol version 2.

### Added

- **Mac host** (`Glide Host.app`, Swift): ScreenCaptureKit capture, VideoToolbox hardware
  encoding (HEVC 4:2:0 low latency, HEVC 4:4:4, H.264 fallback) and CGEvent input injection,
  with the cursor shape sent to the viewer.
- **Windows viewer** (`glide-client.exe`, Rust): Media Foundation hardware decoding through
  D3D11, a flip-model swap chain, raw keyboard and mouse capture, and the Mac cursor shown as the
  native Windows cursor.
- **Hybrid mode:** HEVC 4:2:0 while the screen changes, then a 4:4:4 refinement layer once it
  settles, so text is pixel-exact at rest. `fast` (4:2:0 only) and `sharp` (4:4:4 on every
  frame) are also available. The viewer only offers hybrid and sharp when its GPU decodes the
  embedded HEVC 4:4:4 test clip.
- **View size matching:** the host captures at the viewer monitor's physical size and
  re-captures when the window moves to another monitor, so video is drawn 1:1. An automatic
  display-mode policy (`crisp`, `retina`, `smooth`, `manual`) picks a matching Mac display mode
  and restores the previous one after the viewer disconnects.
- **Either side can connect:** the viewer dials the host (port 7420), or the host dials a viewer
  running `--listen` (`glide-host --connect`, or `connect` in `host.json`), with automatic
  redial and reconnect.
- **Clipboard sync** of text and images in both directions. Clipboard items that password
  managers mark private are not sent unless you opt in.
- **Audio:** Mac system audio is played on the PC through a drift-correcting jitter buffer.
- **File transfer** in both directions: drag and drop, menu pickers, and Finder copy with
  Ctrl+Alt+Shift+V. Received names are sanitized, nothing is overwritten, every file is verified
  with SHA-256, and received files are marked as downloaded (macOS quarantine, Windows
  Mark-of-the-Web).
- **Host menu bar:** connection state, viewer, stream statistics and latency, Disconnect, Pause,
  Pair New Viewer…, Paired Viewers, Display Mode, Send Files to Viewer…, Recent Transfers, Open
  Log, Restart and Quit. The host runs as a per-user LaunchAgent (`tools/install-host.sh`), keeps
  the system awake while hosting and the display awake during a session.
- **Viewer UX:** `config.json` settings, a tray icon, a stats overlay (HUD), a connection bar and
  Glide menu, hotkeys, toasts, borderless fullscreen (F11, Alt+Enter), and window placement
  remembered per monitor. The window stays open across disconnects and reconnects on its own.
- **Latency instrumentation:** a per-stage latency breakdown in the HUD, the host log and the
  menu bar, a glass-to-glass test pattern (`--latency-test`), and `glide-host --encode-bench`.
- **Release packaging:** a `VERSION` file as the single source of the version,
  `glide-host --version` and `glide-client --version`, the version in the host menu and the
  viewer tray menu, and release zips with `SHA256SUMS` built by `tools/release.sh` or the release
  workflow. See [`docs/INSTALL.md`](docs/INSTALL.md).
- Multi-monitor: choose which Mac display to stream from the viewer's Glide menu (**Show Mac
  display**) or cycle with **Ctrl+Alt+Shift+→ / ←**; the Mac menu bar has a matching
  **Streamed Display** submenu. The choice is remembered per host and re-selected on reconnect,
  even if the display's ID changed. Unplugging the streamed display falls back to the main one
  and switches back when it returns. New protocol messages (§3.5, capability bit 13) are ignored
  by older hosts and viewers.
- Input extensions (protocol §3.6, capability bit 12; older hosts and viewers keep the previous
  behavior):
  - Touchpad and high-resolution wheel scrolling arrives on the Mac as smooth pixel scrolling with
    gesture phases; a notched wheel scrolls like a Mac mouse wheel (3 lines per notch).
  - **Relative mouse** for games and 3D apps: **Ctrl+Alt+Shift+G** or Glide menu → Input. The pointer
    is hidden and held in the window and raw mouse motion is sent to the Mac.
  - Caps Lock and Num Lock stay in sync with the PC (its LEDs stay right); with Num Lock off the
    keypad is Home/End/arrows on the Mac too.
  - Media keys: play/pause, next, previous and stop control the Mac; volume keys stay on the PC,
    where the Mac's sound plays.
- Glide menu → **Input**: switch Ctrl as Command (Win as Control) on or off at runtime, and
  **Natural scrolling** (reverses the direction; config `natural_scrolling`).
- Host: `GLIDE_KEYBOARD_TYPE=ansi|iso|jis`, `GLIDE_SCROLL_LINES`, `GLIDE_SCROLL_PIXELS` for tuning.
- `docs/THREAT_MODEL.md`: what pairing protects and what it doesn't, trust in the LAN, and the
  host-dials (listen) mode.
- Both sides' message decoders are fuzzed on every CI run (`cargo test`, `glide-selftest`), and
  CI now runs `cargo clippy` with warnings as errors and a gitleaks secret scan.

- **Virtual display, on by default:** when a viewer connects, the Mac host creates a virtual monitor
  with the viewer's exact pixels and monitor refresh rate and streams it 1:1. The Mac no longer
  renders a 4608 px-wide desktop for ScreenCaptureKit to downscale, a 120/144 Hz viewer gets a
  120/144 Hz panel (less compositor wait), and your monitor's mode is no longer switched to fit the
  viewer. A 4K viewer gets a panel that looks like 1920×1080 at HiDPI, and a 1440p viewer gets
  2560×1440 at 1x. The Display Mode setting still chooses HiDPI or 1x.
  - **With a monitor attached,** the monitor mirrors the virtual display while the viewer is
    connected. There is one desktop at the viewer's size, the viewer sees every window, and nothing
    moves to a hidden screen. Ten seconds after the viewer leaves, the mirror ends, your monitor's
    own mode comes back, and the virtual display is removed.
  - **On a headless Mac** it is the only screen and is kept.
  - **If your monitor already matches the viewer exactly,** Glide streams the monitor.
  - **Options:** `"whenMonitorAttached": "extend"` (beside your monitor, made main) or `"stream"`
    (the old behavior), `"lifetime": "always"`, and `"refreshRate"`.
  - **Opting out:** set `"virtualDisplay": {"enabled": false}` or untick it in the menu. A
    `--display` pin also turns the default off.
  - It uses a private macOS API. Glide falls back to the physical display, with a log line and a
    menu status, if the API is missing or fails.
  - `glide-host --virtual-display-selftest` checks it on your Mac.
  - The display picker lists it as "Glide Virtual Display", and **Automatic** means it.
  - See `docs/VIRTUAL_DISPLAY.md`. No protocol change: ClientHello's `max_fps` carries the
    viewer's refresh rate.

### Security

- **Noise XX handshake** (`Noise_XX_25519_ChaChaPoly_SHA256`) between long-term keys: the Mac's in
  `host-key`, the PC's protected with DPAPI. There are no passwords and no accounts.
- **Key pinning in both directions.** A viewer is paired once with a 6-digit code that both
  screens show and the user confirms on both. The viewer refuses a Mac whose key changed
  ("HOST KEY CHANGED") before revealing its own key.
- ChaCha20-Poly1305 record layer with per-direction counters. Any decryption failure closes the
  connection.
- Pre-authentication limits on both sides: wall-clock deadlines, size-capped records, per-address
  backoff (1 s to 60 s), at most 4 pending connections on the host (2 per source address), and on
  the viewer in listen mode an IP allowlist or trust-on-first-use pinning of the host's address.
- Only an authenticated viewer can replace the active session.
- Mac host: mouse and wheel messages with invalid numbers (NaN, infinity, absurd wheel
  deltas) are dropped. Before, a paired viewer could crash the host with one.
- Viewer: a misbehaving or compromised Mac can no longer exhaust the PC's memory or CPU through
  rapid file offers with huge path lists, endless new cursor shapes or display names, or a tiny
  clipboard PNG with a giant embedded colour profile. Oversized cursor shapes are ignored.
- Both sides: checking a file offer for a name that is both a file and a folder is now
  O(n log n) instead of building every folder prefix (~1 GB for a hostile 10 000-file offer).

### Changed

- Volume and mute keys pressed in the viewer now change the PC's volume instead of being sent to
  the Mac (where they had no effect).
- Received file names: if shortening a very long name would leave a Windows device name such as
  `CON`, it gets a `_` prefix like any other device name (protocol §6.3, new step 5).

These matter only if you ran a development build from before this release (protocol v1):

- Protocol v2 is not compatible with v1. Each side recognizes the other's version and says that
  the other side needs an update.
- The v1 password is gone. `host.json` `salt`/`password`, `password.dpapi`, `--password` and
  `GLIDE_PASSWORD` are ignored (and left in place), and each viewer must be paired once.

### Fixed

- The host follows the display that is actually live instead of the main display it saw at
  launch, so input keeps covering the whole screen after the lid closes or a monitor is swapped.
- The host no longer treats a removed display as online: CoreGraphics returns -1, not 0, for a
  vanished display ID.
- Mouse: clicks landed up to 1 point up and to the left of the pointer, increasingly toward the
  right and bottom edges, and the last row and column of the Mac's screen were unreachable (Dock
  autohide at the bottom, hot corners on the right).
- Horizontal scrolling (tilt wheel, touchpad) went the wrong way on the Mac.
- Mouse movement now carries motion deltas, so 3D views, games and some sliders respond to drags.
- After opening the Glide menu with Ctrl+Alt+Shift+Space, typing a plain letter could fire a viewer
  hotkey (H toggled the stats, D reconnected) and the next Space could stay held down on the Mac.
- Keys held when pressing Ctrl+Alt+Del (or when a UAC prompt appears) no longer stay held on the Mac.
- Mac volume and media keys sent by the viewer now act on the system (they were ordinary key
  events the system ignored); media play/pause/next/previous no longer vanish when the viewer has focus.
- ISO keyboards: the key left of 1 and the extra key left of Z were swapped on Macs with an ISO
  keyboard type, as macOS's own driver swaps them.
- Keyboard and mouse input reach the network through a queue, so neither a file upload nor a
  network that silently drops makes the PC's keyboard freeze. Reconnect, Disconnect and Forget
  host no longer hang the viewer on a stalled connection, a send that makes no progress for 5 s
  ends the connection, and if Windows dropped the keyboard hook after a stall the viewer puts it
  back.
- After a stall, queued mouse motion is merged instead of replaying seconds of stale movement on
  the Mac, and a high-rate mouse in relative mode no longer builds a backlog.
- Relative mouse: the pointer is held in the window again after Ctrl+Alt+Del or a UAC prompt
  (before, it could wander out).
- Viewer: a bitmap on the Windows clipboard with unusual colour masks could crash debug builds
  and got wrong colours in release builds. `--probe`'s video parameter parser no longer panics
  on a truncated NAL unit.

### Known limitations

- Host: macOS 14 or later on Apple silicon only. Viewer: Windows 10/11 x64 only. One viewer at a
  time.
- LAN only, over TCP. There is no relay or NAT traversal.
- The Mac app is signed ad hoc and not notarized; see [`docs/INSTALL.md`](docs/INSTALL.md) for the
  Gatekeeper workaround. With an ad-hoc signature, macOS may ask for the privacy permissions again
  after each update.
- The viewer exe is not code-signed, so Windows SmartScreen warns on first run.
- The virtual display (on by default) uses `CGVirtualDisplay`, an undocumented macOS API that an
  update may change; Glide falls back to the physical display if it's unavailable. While a viewer
  is connected, an attached monitor mirrors the virtual display, so its resolution changes for the
  session and is restored afterwards. Turn it off in the menu bar or with
  `"virtualDisplay": {"enabled": false}` ([`docs/VIRTUAL_DISPLAY.md`](docs/VIRTUAL_DISPLAY.md)).
- A paired Mac that floods the viewer with video-configuration messages can make the viewer
  unresponsive until it disconnects (see [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md)).

[Unreleased]: https://github.com/sudoBrandino/glide/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/sudoBrandino/glide/releases/tag/v0.2.0
