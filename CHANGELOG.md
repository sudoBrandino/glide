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

### Changed

- **Windows viewer: updated cryptography libraries** (x25519-dalek 3, chacha20poly1305 0.11, hkdf 0.13,
  sha2 0.11). The algorithms, key sizes, nonce layout and wire format are unchanged, so viewers and
  hosts of any version still pair and connect with each other; known-answer tests pin this.

## [0.4.0] - 2026-11-18

Saved connections on the Windows viewer, and a first preview of the reverse direction: controlling
a Windows PC from a Mac. Protocol version 2 (unchanged). Screen Recording and Accessibility grants
from 0.3.x carry over.

### Added

- **Mac host: a Settings window.** Menu bar → **Settings…** (⌘,), or the setup window's
  **Settings…** button, gathers everything Glide Host keeps in one place: start at login, the PC's
  address, listening, display mode and virtual display, paired viewers (with key, pairing date,
  Unpair and Pair New Viewer), clipboard, audio and file transfer (with the received-files folder),
  and **Reset Settings**, which keeps your paired viewers. Display changes apply at once, sharing
  changes from the next connection.
- **Mac host: connecting out to the PC is now optional at startup.** Turn off **Connect out to the
  PC automatically when Glide Host starts** (Settings → Connection, host.json
  `"connectAtLaunch": false`) to keep the PC's address without dialing it at login; the menu bar's
  new **Connect to PC** item (or **Connect Now** in Settings) dials it when you want, and **Stop
  Connecting to PC** stops it. The default is unchanged: a saved address is dialed at startup.
- **Mac host: clipboard sync and audio can be switched off** on the Mac (Settings → Sharing,
  host.json `"clipboard": {"enabled": false}` and `"audio": {"enabled": false}`).

- **Control a Windows PC from a Mac (preview).** Glide now works in the other direction too: run
  `glide-host.exe` on the PC and `glide-viewer` on the Mac. It pairs the same way (a 6-digit code
  confirmed on both screens) and streams hardware H.264/HEVC with keyboard, mouse and the PC's
  cursor. Command, Control and Option on the Mac map to Control, Windows and Alt on the PC. The PC
  listens on port 7421, so it can run next to the existing viewer. Audio, clipboard, file transfer
  and the sharp 4:4:4 layer are not in this direction yet. See `docs/WINDOWS_HOST.md`.
- **Windows viewer, saved connections:** the viewer remembers the Macs you connect to. *Connections…*
  in the Glide menu and the tray lists them (grouped, with pairing state and last use) and switches
  between them; the tray's **Connect to** submenu switches in one click. `--connection NAME` starts
  with a saved connection (and makes it the default), `--list-connections` prints them. The Mac
  address you already set up becomes the first saved connection.
- **Windows viewer, Settings window:** *Settings…* in the Glide menu and the tray now opens a real
  settings window instead of the config file: start at sign-in, connecting right away at sign-in,
  stream mode, keyboard and scrolling, audio, clipboard, file transfer (folder and limits), the
  listen port, allowed Mac addresses, paired Macs (unpair) and this viewer's key fingerprint. Typed
  values are checked before they are saved; most changes apply at once, and Glide offers to restart
  for the few that need it. The config file is still one click away (Advanced).
- **Mac viewer, Connections and Settings windows (preview).** `glide-viewer` now has a full
  connection manager: the saved PCs with address, pairing state and last use, grouped, with
  favorites first and a search field. Connect with Return or a double-click; add, edit (name,
  address, port, group, favorite), duplicate, remove and unpair from buttons or the right-click
  menu. Remove and Unpair ask first, and removing a connection also forgets its pairing unless
  another connection uses the same address, as in the Windows viewer. **Settings…** (⌘,) holds the
  modifier mapping (applied to a running session at once), a new **Open sessions in full screen**
  option, and this Mac's viewer key fingerprint with a Copy button. The app has standard Glide
  Viewer, Edit and Window menus. Disconnect (⌃⌥⇧Q, or closing the session window) returns to the
  Connections window instead of quitting; launching with no arguments opens that window and never
  connects on its own.
- **Mac viewer, session shortcuts:** a way out of a streaming session from the keyboard. ⌃⌥⇧Q
  disconnects, ⌃⌥⇧F toggles full screen, ⌃⌥⇧K releases the keyboard so ⌘Tab and other Mac
  shortcuts work on the Mac until you click back into the session, ⌃⌥⇧D reconnects, and
  ⌃⌥⇧Space opens a session menu at the pointer. They are never sent to the PC (the Control, Option
  and Shift presses included), work with and without the Accessibility permission and in full
  screen, and follow the physical Mac keys whatever the modifier mapping. The menus and Settings
  show them, and a short hint appears when a session starts and when it enters full screen.
  The menus use them as the key equivalents for Disconnect, Reconnect and full screen.

### Changed

- **Windows viewer, start at sign-in:** when Windows starts the viewer at sign-in, it now opens
  without connecting: the window and tray icon are there, but it doesn't dial the Mac or wait for
  it until you press Enter or click in the window, or choose **Connect** in the Glide menu or the
  tray. Starting it yourself still connects right away. Existing sign-in entries switch over by
  themselves the next time the viewer starts. To connect at sign-in as before, turn on
  **Connect to the Mac right away when Glide starts at sign-in** in Settings → General.

### Fixed

- **Mac host:** a PC address given as a bare IPv6 address (`fe80::1`, no brackets) was dialed as
  host `fe80`, port 1. It is now dialed on port 7420; use `[fe80::1]:PORT` for another port.

### Changed

- **Downloads:** the Windows zip now also holds `glide-host.exe`, and Glide Host for the Mac now
  also holds `glide-viewer` (Homebrew links it as `glide-viewer`). `install.ps1` installs and
  updates both Windows programs together.

## [0.3.1] - 2026-11-15

Fixes from a fresh-install test on a MacBook. Protocol version 2 (unchanged). Screen Recording and
Accessibility grants from 0.3.0 carry over.

### Added

- **Mac setup:** when **Allow…** opens the Screen Recording or Accessibility list in System
  Settings, a small panel beside it shows Glide Host's icon. If Glide Host isn't in the list, drag
  the icon in instead of hunting for the app with the **+** button. The panel closes once the
  permission is granted or System Settings closes.

### Changed

- **Mac, laptop with the lid open and no external monitor:** Glide no longer changes the built-in
  display's resolution while the PC is connected. It streams the built-in display as it is, scaled
  to fit the PC's window, instead of mirroring a PC-sized virtual display onto it. With an external
  monitor, or with the lid closed, nothing changes. Set `whenMonitorAttached` to `"mirror"` to keep
  the old behavior.

## [0.3.0] - 2026-11-14

Setup without Terminal, connections in either direction, and the fixes from a full-codebase
review. Protocol version 2 (unchanged; the pairing and backoff rules in `docs/PROTOCOL.md` §2.3–2.5
changed). Updating from 0.2.0 asks for Screen Recording and Accessibility once more, because
releases are now signed with the project's own certificate; after that the grants carry over.

### Added

- **Setup without Terminal.** The Mac host ships as a `.dmg`: drag Glide Host to Applications and
  open it. A setup window walks through starting at login, Screen Recording and Accessibility
  (with live status and the right Settings page), the connection (this Mac's address, and the
  PC's) and pairing. It opens by itself while something is missing, from the menu bar (Set Up
  Glide Host…), and when the app is opened again. Opening a newer download while Glide Host runs
  offers to replace it. On Windows, running `glide-client.exe` opens a setup window that installs
  the viewer (Start menu entry), asks for the Mac's address with a Test button, adds the firewall
  rule with one administrator prompt and can start Glide at sign-in. Both reopen from the Glide
  menu / tray (Set up…).
- **Either side can connect.** The host always listens and also dials the PC once it knows its
  address; the viewer dials the Mac and also listens. So when the network only allows one
  direction (say, a Mac on its own segment that may reach the PC), Glide still connects, without
  choosing a "mode". `"listen": false` (host.json) / `"accept_incoming": false` (viewer) or
  `--no-listen` on either side turn listening off.
- The Mac host starts at login as a login item (System Settings → General → Login Items) instead
  of a script-written LaunchAgent; `glide-host --login-item on|off|status` does the same from a
  script. The host now has an app icon.

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

### Fixed

- A Glide Host opened from Finder or the Dock was taken for the login item (macOS sets the same
  variable for both), so a new download opened next to a running host quit after a minute instead
  of offering to replace it, and Restart / Quit Until Next Login assumed launchd would restart it.
- After an update, macOS refused to start the login item (it is tied to the exact build). Opening
  the new Glide Host now registers it again, and the login item takes over.

- Updating by dragging a new Glide Host over the running one and opening it now restarts into
  the new version. Before, the host stopped and nothing started again. The old LaunchAgents are
  removed only once the new copy is in place, and a failed copy puts the old app back.
- A `host.json` that can't be read is never overwritten any more (saving the PC's address,
  finishing setup, `--set-connect`): it used to be replaced with defaults, which dropped the
  paired viewers. The setup window shows what is wrong with the file instead.
- The Mac no longer keeps capturing the screen when a viewer disconnects while capture is still
  starting, and ending a session is now done on that session's own queue (a viewer replacing a
  half-open session could crash the host or start a second dialer).
- On networks where only the Mac can reach the PC, pairing no longer stalls for up to a minute:
  the viewer doesn't count "pairing closed" answers or leftover connections against the Mac, the
  host doesn't charge its own failed dials to the PC's address, and the host doesn't dial an
  unpaired PC until its pairing window opens.
- When the Mac's address changes (a new DHCP lease), a PC that only accepts the Mac's connections
  lets it back in after it proves the paired key, instead of refusing it until it is re-paired.
  Refused connections show in the viewer's status line.
- A viewer reporting a tiny window size can't make the Mac capture 0×0 any more.
- `install.sh` copies the new app next to the old one and swaps it in, so a failed copy leaves the
  old host installed. It reuses a copy the setup window put in /Applications instead of adding a
  second one.

### Security

- Pairing prompts on both sides: Cancel is now the default button (Return/Escape), confirming is
  possible only after 1 s, and the prompt no longer takes keyboard focus from the app you are
  typing in. The viewer shows the address the connection actually came from.
- An unpaired viewer accepts a pairing started by a Mac that connects to it only for 15 minutes
  after it starts or its setup dialog is used (or from the tray's *Allow the Mac to pair*), and
  doesn't ask for pairing at all when the Mac's pairing window is closed.
- Release builds of the viewer ignore the test variables (`GLIDE_PAIR_CONFIRM` and friends), so a
  variable left set can't confirm a pairing; they need the `test-hooks` build feature.
- `install.ps1` runs its elevated firewall step through PowerShell's full path with an encoded
  command, and quotes paths with typographic apostrophes correctly. `install.sh` stops when a
  GitHub build-provenance check fails (when the GitHub CLI can run it).
- Unauthenticated connections can no longer grow the host's log without bound; security events
  (unknown viewers, pair requests) have their own budget so connection noise can't hide them.
  Glide v1 viewers now go through the same rate limit as everyone else.
- The release workflow loads the signing identity only for tag pushes, not for pull requests.

### Changed

- Releases are signed with the project's self-signed certificate ("Glide Release Signing")
  instead of ad hoc, so the Screen Recording and Accessibility grants survive updates. The first
  update to such a build asks for them once more. `tools/make-host-app.sh` can sign from a separate
  keychain (`GLIDE_SIGN_KEYCHAIN`).

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

[Unreleased]: https://github.com/sudoBrandino/glide/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/sudoBrandino/glide/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/sudoBrandino/glide/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/sudoBrandino/glide/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sudoBrandino/glide/releases/tag/v0.2.0
