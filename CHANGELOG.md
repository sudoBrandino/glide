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
- Multi-monitor: choose which Mac display to stream from the viewer's Glide menu (**Show Mac
  display**) or cycle with **Ctrl+Alt+Shift+→ / ←**; the Mac menu bar has a matching
  **Streamed Display** submenu. The choice is remembered per host and re-selected on reconnect,
  even if the display's ID changed. Unplugging the streamed display falls back to the main one
  and switches back when it returns. New protocol messages (§3.5, capability bit 13) are ignored
  by older hosts and viewers.

- **Virtual display (optional, off by default):** the Mac host can create a virtual monitor sized to
  the viewer and stream it instead of its own screen, so a headless Mac, or a Mac whose screen
  doesn't match the viewer, streams pixel-perfect without BetterDisplay. A 4K viewer gets a panel
  that looks like 1920×1080 at HiDPI, and a 1440p viewer gets 2560×1440 at 1x. The existing Display
  Mode setting chooses HiDPI or 1x. The display is kept 30 s after a disconnect so reconnects don't
  move windows, and it can be kept always on or made the main display. Turn it on in the menu bar
  (*Virtual Display*) or in host.json `"virtualDisplay"`. It uses a private macOS API: Glide falls
  back to the physical display if the API is missing or fails. Run
  `glide-host --virtual-display-selftest` once before turning it on. See `docs/VIRTUAL_DISPLAY.md`.
  No protocol change.

### Changed

### Fixed

### Security

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

### Changed

These matter only if you ran a development build from before this release (protocol v1):

- Protocol v2 is not compatible with v1. Each side recognizes the other's version and says that
  the other side needs an update.
- The v1 password is gone. `host.json` `salt`/`password`, `password.dpapi`, `--password` and
  `GLIDE_PASSWORD` are ignored (and left in place), and each viewer must be paired once.

### Fixed

- The host follows the display that is actually live instead of the main display it saw at
  launch, so input keeps covering the whole screen after the lid closes or a monitor is swapped.

### Known limitations

- Host: macOS 14 or later on Apple silicon only. Viewer: Windows 10/11 x64 only. One viewer at a
  time.
- LAN only, over TCP. There is no relay or NAT traversal.
- The Mac app is signed ad hoc and not notarized; see [`docs/INSTALL.md`](docs/INSTALL.md) for the
  Gatekeeper workaround. With an ad-hoc signature, macOS may ask for the privacy permissions again
  after each update.
- The viewer exe is not code-signed, so Windows SmartScreen warns on first run.

[Unreleased]: https://github.com/sudoBrandino/glide/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/sudoBrandino/glide/releases/tag/v0.2.0
