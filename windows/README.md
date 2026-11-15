# Glide Windows client (`glide-client.exe`)

Rust viewer for the Glide remote desktop: it decodes HEVC/H.264 with Media Foundation on the
GPU through D3D11, renders through a flip-model swap chain, and forwards keyboard and mouse input.
The wire protocol is defined in `../docs/PROTOCOL.md`.

## Layout

| path | what |
|---|---|
| `src/protocol.rs`, `src/crypto.rs` | Message codec and the ChaCha20-Poly1305 record layer. Works on any OS. |
| `src/noise.rs`, `src/handshake.rs`, `src/identity.rs` | Security v2: Noise XX (checked against the official vectors in `../docs/noise-vectors.json`), the Glide preambles/payloads/pairing commitment/SAS (against `../docs/test-vectors.json` and the Rust-generated `../docs/test-vectors-rust.json`), and the viewer's key (`identity.dpapi`). |
| `src/net.rs` | TCP (NODELAY), shared encrypted writer, receive thread, 1 Hz ping, RTT and clock offset. Includes `--listen` reverse mode. |
| `src/audio.rs` | Audio jitter buffer (priming, drift-correcting resample, underrun/overflow handling). Platform independent, unit-tested. |
| `src/hid.rs` | Set-1 scancode → USB HID usage table, plus the Ctrl↔Cmd / Win↔Control remap. Unit-tested. |
| `src/config.rs`, `src/hotkeys.rs`, `src/hud.rs` | Config file (load/save/migration, CLI-vs-config precedence, per-monitor window placement), hotkey table, stats-HUD text. Pure Rust, unit-tested. |
| `src/clipboard.rs` | Clipboard sync logic without Win32: CRLF↔LF, echo guard, DIB↔PNG (`png` crate). Unit-tested. |
| `src/files.rs` | File transfer (PROTOCOL.md §6) without Win32: name sanitizer, receiver (temp → SHA-256 → no-overwrite rename), sender (folder walk, chunking), `Service` (transfers + ack window). Unit-tested, incl. a two-service loopback. |
| `src/annexb.rs`, `src/bench.rs` | Annex-B access-unit splitting, and the headless benchmark driver. |
| `src/setup.rs` | Setup logic, platform independent: install folder, "offer to install?", Mac address check and port test, this PC's address, the firewall PowerShell (check + elevated allow). |
| `src/win/` | Windows only: `d3d` (device + DXGI device manager), `decoder` (MF decoder MFT), `render` (shaders, swap chain, text panels), `app` (window, input, cursor, fullscreen, hotkeys, the session loop incl. both mode), `clipboard` (clipboard listener/apply), `files` (drag & drop, notifications, open folder), `audio` (WASAPI output), `cursor`, `probe`, `bench_decoder`, `dpapi` (identity key encryption), `prompt` (pairing dialog), `setup` (setup dialog, self-install, firewall, start at sign-in), `placement` (monitors), `tray`. |
| `res/`, `build.rs` | Icon, manifest (themed controls, PerMonitorV2), pairing dialog and version info, linked into the exe: MinGW `windres` for the GNU target, `rc.exe` (via `embed-resource`) for MSVC. Regenerate the icon with `../tools/make_icon.py`. |
| `assets/` | Small clips embedded in the exe for `--probe`. Regenerate them with `../tools/make_streams.sh --clips-only`. |

## Build (on macOS, cross-compiling)

```sh
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"   # or ~/.cargo/bin
cargo test                                                    # native unit tests, including the test vectors
cargo build --release --target x86_64-pc-windows-gnu          # needs x86_64-w64-mingw32-gcc (Homebrew mingw-w64)
scp target/x86_64-pc-windows-gnu/release/glide-client.exe <pc>:glide/glide-client.exe      # or ../tools/deploy-viewer.sh
```

`.cargo/config.toml` sets the MinGW linker and `+crt-static`. The exe needs only system DLLs.
Shaders are compiled at runtime with `D3DCompile` from `d3dcompiler_47.dll`, which ships with Windows.

## Run

```
glide-client.exe                               (uses the config file; opens the setup dialog when nothing is set up)
glide-client.exe <host[:port]> [--no-listen] [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd] [--no-clipboard] [--clipboard-sync-secrets] [--no-audio] [--bench SECONDS] [--probe]
glide-client.exe --listen [PORT] [same options]
glide-client.exe --setup                       (open the setup dialog)
glide-client.exe --connection NAME [same options]                   (use a saved connection; it becomes the default)
glide-client.exe --list-connections                                 (print the saved connections)
glide-client.exe --forget-host [host[:port] | --listen [PORT]]   (unpair, then exit)
glide-client.exe --identity                                         (print this viewer's key fingerprint)
```

### Setup dialog (no command line needed)

Double-click `glide-client.exe`. When nothing is set up yet, or the exe runs from outside the install
folder (for example Downloads), the **setup dialog** opens first. It is also in the Glide menu and the
tray icon (*Set up…*), and `--setup` opens it.

- **Mac's address** and **Test**: a TCP connect to the Mac's Glide port, with the answer below it.
- **Let the Mac connect to this PC** (config `accept_incoming`, on by default) and **Allow in Windows
  Firewall** (UAC shield): one elevated PowerShell step that removes inbound Block rules for the exe
  (Windows adds one when someone cancels its own prompt) and adds an inbound Allow rule "Glide Viewer"
  for TCP 7420 on Private and Domain networks. The dialog checks the rules (and warns when the network
  is set to Public) without elevation.
- **This PC's address**: to type into the Mac's setup window when only Mac → PC connections work.
- **Start Glide when I sign in**: the `HKCU\…\Run` value "Glide Viewer" (an install.ps1 Startup
  shortcut is replaced, since it may carry old arguments).
- **Install Glide Viewer on this PC** (shown when running from elsewhere): copies the exe (and
  README.txt/LICENSE.txt beside it) to `%LOCALAPPDATA%\Glide`, or to the folder the Start Menu
  shortcut "Glide Viewer.lnk" already points to; writes that shortcut; closes a running viewer first
  (asks); starts the installed copy. The downloaded file stays where it is. Declining remembers this
  exe (`portable_exe`) so it doesn't ask again.
- **Connect** saves the settings. From the menu it restarts the viewer with them.
- A Start Menu shortcut that carries arguments (older install.ps1) is rewritten without them, so the
  config decides.
- Test hooks (builds with `--features test-hooks` only, see below): `GLIDE_SETUP_DUMP=x.bmp` saves a
  capture of the dialog; `GLIDE_SETUP_ANSWER=connect|cancel` presses a button after about 0.5 s.

### Saved connections

The viewer remembers the Macs it connects to. It still connects to one Mac at a time; switching
saves the choice and restarts the viewer onto it (like **Connect** in the setup dialog).

- **Connections window** (Glide menu or tray → *Connections…*): the saved Macs, grouped, with
  their pairing state and when each was last used. Connect, add, edit, duplicate, remove and unpair
  from there. Like *Set up…*, a Mac connecting to this PC may start pairing while it is open.
- **Tray → Connect to**: up to 10 saved connections (favorites first, then the most recently
  used); a check marks the active one. Pick another to switch.
- `--connection NAME` picks one by name, id or address and makes it the active one, so plain
  launches use it from then on. It can't be combined with a positional host or `--listen`. An
  unknown name exits with code 2 and lists the saved names.
- `--list-connections` prints them (`*` = active) with address, group and pairing state.
- Config: `connections` (list of `{ "id", "name", "platform": "mac", "address", "accept_incoming",
  "group", "favorite", "last_connected" }`) and `active_connection` (an id). The active connection
  is mirrored into `host` / `accept_incoming`, which the connect path and pairing still use; a
  `host` written by the setup dialog, by hand or by an older viewer is added to (or updates) the
  list when the config loads. A session started with a host on the command line doesn't change
  the list.
- Pairing is per connection. A Mac paired while this PC was only listening is pinned under
  `listen:PORT`; when its address is then entered (Set up, or an upgrade from an older viewer)
  that pin moves to the new connection, so other saved Macs don't inherit it.
- Test hook (`--features test-hooks` builds only): `GLIDE_CONNS_DUMP=x.bmp` saves a capture of the
  Connections window after about 0.5 s and closes it.

### Config file, identity and pairing

Settings live in `%APPDATA%\Glide\config.json` (set `GLIDE_CONFIG_DIR` to use another folder). The file
is created on first run and rewritten when settings change. Edit it by hand, or use the tray icon → *Open config file*.

```json
{
  "version": 1,
  "listen_port": 7420,      // where the Mac can connect to this PC (glide-host --connect)
  "host": null,             // "mac.local:7420" = dial the Mac (and keep listening, see below)
  "accept_incoming": true,  // with "host": also listen on listen_port; false = dial only
  "connections": [],        // saved connections (see Saved connections); the active one sets "host"
  "active_connection": null, // id of the saved connection in use ("c1"), or null
  "portable_exe": null,     // an exe the user chose to run without installing (setup dialog)
  "mode": null,             // "fast" | "hybrid" | "sharp"; null = auto (hybrid if 4:4:4 decodes)
  "ctrl_as_cmd": true,       // Ctrl → Command, Win → Control (menu → Input)
  "natural_scrolling": false, // reverse the wheel/touchpad direction sent to the Mac (menu → Input)
  "hud": false,             // stats overlay, toggled with Ctrl+Alt+Shift+H
  "bar_pinned": false,      // connection bar always visible (menu → Pin connection bar)
  "audio": true,            // play the Mac's sound (false = --no-audio)
  "audio_muted": false,     // Ctrl+Alt+Shift+A
  "clipboard": true,        // clipboard sync with the host (false = --no-clipboard)
  "clipboard_sync_secrets": false, // also send clipboard items password managers mark private
  "allowed_peers": [],      // listen mode: IPs/CIDRs allowed to connect; [] = pin the first host's IP
  "pinned_hosts": {         // host keys pinned by pairing, per target ("host:port" or "listen:PORT")
    "listen:7420": { "key": "5714…0c36", "name": "Mac mini", "paired": "2026-11-06T13:05:09Z" }
  },
  "file_transfer": true,    // drag & drop to the Mac, Ctrl+Alt+Shift+V, receiving (caps bit 11)
  "file_receive": true,     // accept files the Mac sends
  "download_dir": null,     // null = <Downloads>\Glide; "%USERPROFILE%\..." variables are expanded
  "file_max_total_bytes": 8589934592,
  "file_max_files": 10000,
  "last_monitor": "\\.\DISPLAY1",
  "windows": { "\\.\DISPLAY1": { "x": 0, "y": 0, "w": 2400, "h": 1400, "maximized": false, "fullscreen": true, "mon_w": 3840, "mon_h": 2160 } },
  "last_display": {         // Mac display picked in the viewer, per target, by identity (PROTOCOL.md §3.5)
    "listen:7420": { "id": 5, "vendor": 4268, "model": 16999, "serial": 825380938, "name": "DELL U2723QE" }
  }
}
```

(The real file is plain JSON, without comments.)

- **Precedence:** command-line flags win over the config file.
  - A positional `host` (both mode; `--no-listen` = dial only; `--listen PORT` sets the port it
    listens on), then `--listen [PORT]` alone (listen only), then the config's `host` (both mode
    unless `"accept_incoming": false`), then listening on `listen_port`. `--connection NAME`
    first makes that saved connection the config's `host`.
  - `--mode` wins over `"mode"`, which wins over auto.
  - `--no-ctrl-as-cmd` / `--ctrl-as-cmd` win over `"ctrl_as_cmd"`.
  - `--no-audio` wins over `"audio"`.
  - `--no-clipboard` wins over `"clipboard"`.
- **Identity and pairing (security v2, `docs/PROTOCOL.md` §1–2):** no password.
  - The viewer's key is `identity.dpapi` next to `config.json` (DPAPI, current user: only this Windows account on this PC can use it). It is created on first run; `--identity` prints its fingerprint.
  - First connection to a host: the Mac must be in pairing mode (Glide menu → *Pair New Viewer…*, or `glide-host --pair`). A dialog shows a 6-digit code and both key fingerprints; click *Codes Match — Pair* only if the Mac shows the same code, and confirm there too. The host key is then pinned in `pinned_hosts`.
  - The dialog names the address it is pairing with: the address dialed, or, when the Mac connected to this PC, the IP that connection came from. *Cancel* is the default button, *Codes Match — Pair* stays disabled for a second after the dialog appears (and again when it is activated from the keyboard), so a Return or Space typed just then can't confirm it. It doesn't take the keyboard from another app: its taskbar button flashes instead.
  - Not paired yet / Mac not in pairing mode: the window says so ("the Mac isn't accepting pairing — … Pair New Viewer…") and keeps retrying, so opening the pairing window on the Mac is enough. The Mac's handshake says whether its pairing window is open; while it is closed the viewer doesn't send a pair request at all.
  - **Inbound pairing window:** an unpaired viewer accepts a pairing started by a Mac that *connects to this PC* only for 15 minutes after Glide starts (which includes the setup dialog's *Connect*), after *Set up…* is opened, after *Forget host*, or after tray → *Allow the Mac to pair*. Outside it, such a connection is closed before the pairing prompt and the status line says how to allow it. This keeps first setup working on a network where only the Mac can connect (start the viewer, then open *Pair New Viewer…* on the Mac), without letting any host on the LAN raise the prompt at any time. One successful pairing closes the window. Pairing when this PC dials the Mac, and re-pairing a host whose key is already pinned, don't need it.
  - A different host key than the pinned one: "HOST KEY CHANGED …", and the viewer never reveals its own key to it. If the Mac was really reset: tray → *Forget host (unpair)…*, then pair again.
  - If the Mac removed this viewer, the next attempt asks to pair again (still requiring the pinned Mac key).
  - Pre-auth limits: until the host has proven its pairing commitment the 5 s pre-auth deadline applies (wall clock); the pairing dialog then has 120 s in total.
  - v1 leftovers: `password.dpapi` is left in place but not read (it is mentioned once in the log); `--password` and `GLIDE_PASSWORD` are ignored; a plaintext `"password"` key in `config.json` is removed. Older key names (`port`, `listen`, `connect`, `no_ctrl_as_cmd`) are still migrated.
- **Window:** the window placement is remembered per monitor: the position, the size, and whether it is maximized or fullscreen.
  - At startup the window reopens on the last monitor it was on, in the same state.
  - If that monitor is gone, it uses the saved state of the monitor under the cursor, or opens centered.
  - A saved rect that no longer fits (for example after a resolution change) is clamped into the monitor's work area.
- **Listen-mode admission control** (defense in depth; see `src/peers.rs`):
  - **Allowlist:** if `allowed_peers` is non-empty, connections from any other IP are closed right after `accept()`, before a single handshake byte is sent or read. Entries are IPs or CIDRs, for example `"192.168.1.50"` or `"192.168.1.0/24"`. Refused connections are shown in the status line, not only in the log.
  - **Trust on first use:** if `allowed_peers` is empty, the IP of the first peer that completes an authenticated session is pinned there (logged, and shown in the "Connected" toast). Tray → *Forget host (unpair)…* clears it together with the pinned key.
  - **The Mac's address changes (DHCP):** while `allowed_peers` holds the single plain address that trust on first use wrote and a host key is pinned, a connection from another address still gets a handshake, but it must present the pinned host key before the viewer sends anything about itself (a different key is refused before msg3, and a new key can't pair this way). It is treated like an unpinned peer (global budget) and backs off harder (4 s, 32 s, then 60 s). When it authenticates, the pin moves to the new address ("the Mac's address changed to …" in the toast). To refuse every other address before the handshake regardless, write the entry as a CIDR (`"192.168.1.50/32"`) or list several entries.
  - **Backoff:** a failed handshake blocks the peer for 1 s, doubling on each further failure up to 60 s. Connections from a blocked peer are dropped without a handshake, and a successful session resets it. Peers are tracked per IPv4 address and per IPv6 /64, so a peer can't escape by rotating addresses within its /64. Not counted as failures: the host's "unknown viewer", "pairing window closed" and "busy" answers, the viewer not asking to pair because a pairing window is closed, and a connection closed before the host sent anything (one the Mac gave up on while it waited in the listen backlog). So opening *Pair New Viewer…* on the Mac is never answered by a blocked redial.
  - **Global budget (unpinned only):** while nothing is pinned, more than 10 failed handshakes from all peers within 60 s refuse every unpinned peer for 60 s. Pinned or allowlisted hosts are never affected.
  - **Pre-auth timeout:** a peer that hasn't completed the handshake after 5 s is disconnected.

  These limit who may start a handshake; the host's pinned key is what authenticates it.
- **Tray icon:** Connect / Disconnect / Reconnect, Stats overlay, Mute, Allow the Mac to pair (listening and not paired), Set up…, Open config file, Forget host (unpair)…, Quit.
  - *Disconnect* also stops listening, so the host can't reconnect until you choose *Connect*.
  - Left-click brings the window to the front.


- **The viewer survives disconnects.** The window opens right away and shows a centered status line, for example
  "Waiting for host on port 7420…".
  - In `--listen` mode it goes back to listening after every disconnect. In connect mode it retries every 2 s.
  - **Both mode** (the Mac's address is known and `accept_incoming` is on, the default): one loop,
    one connection at a time. Each round it first takes a Mac connection that arrived while it was
    busy (it waits in the kernel backlog), else dials the Mac with a 1.5 s connect timeout, else waits
    up to 2 s for the Mac to dial in. Whichever direction the network allows connects; the status
    line says "Connecting to … (the Mac can also connect to this PC)". If port 7420 is taken it
    dials only and says so. The pin is stored under the address (`host:port`) for both directions;
    a pin under `listen:PORT` (a viewer that used to listen) is used and copied to the address.
  - While disconnected, the last picture stays on screen, dimmed, under a status line such as "Connection lost — …" or "Not paired with … yet — …".
  - Held keys and buttons are released, and local keys stop being captured until the host is back.
  - A new connection resets the decoders and canvas through the normal VideoConfig/SharpLayerConfig flow.
  - Fullscreen is kept across reconnects.
  - Only closing the window exits.
- **View size:** ClientHello reports the physical size of the monitor the window opens on (the one under
  the cursor). With NVIDIA DSR this is the DSR desktop size, for example 3072x1728.
  - When the window moves to another monitor, or on a display or DPI change, the viewer sends
    `ViewSize` (0x15), debounced by 300 ms. The host then re-captures at that size.
  - The title bar shows `view WxH`.
  - Video that matches the window, or fits within about 6% of it, is drawn 1:1 and centered, never resampled.
  - `GLIDE_VIEW=WxH` pins the reported size.
- `--bench` pairs on the console: it prints the code and asks `[y/N]` (pipe `y` into it to script it;
  `GLIDE_PAIR_CONFIRM=yes|no` works in `test-hooks` builds only).
- `--listen [PORT]` is reverse connect. It binds `0.0.0.0:PORT` (default 7420) and accepts the host's
  connection (`glide-host --connect PC:PORT`). The GUI viewer accepts again after each disconnect; `--bench` accepts only once. The protocol is unchanged: the viewer still writes first (it is the Noise initiator).
  Use this mode when the firewall blocks PC → Mac. A Windows Firewall rule on the PC can then allow
  only the Mac's address to reach `glide-client.exe`. Such a rule is bound to the exe's path, so
  keep the exe at that path.
- `--mode` takes one of three values:
  - `fast`: 4:2:0 only.
  - `sharp`: 4:4:4 on every frame.
  - `hybrid` (protocol v1.1, §3.1): 4:2:0 while the screen changes, plus a 4:4:4 refinement layer once it settles.

  The default is `hybrid` when this PC can decode HEVC 4:4:4, otherwise `fast`.
  The client advertises the HEVC 4:4:4 capability only if the embedded 4:4:4 test clip
  actually decodes on the GPU at startup. If `sharp` or `hybrid` is requested without that capability, the client falls back to `fast`.
- Canvas model (§3.1): every decoded layer is converted into a video-sized RGB10A2 canvas, and each present draws that canvas.
  - Base-layer frames that carry update rects (and are not keyframes) are applied with scissor rects only.
  - Sharp-layer frames are decoded by a second, independent decoder (AYUV output) and replace the whole canvas.
  - Resizing or exposing the window re-presents the canvas without needing a new frame.
  - The title bar shows `hybrid [4:4:4]` while the sharp layer is on screen, along with sharp and rect frame counts.
- **Viewer hotkeys.** These are handled locally and never sent to the host.

  All the letter hotkeys use **Ctrl+Alt+Shift**, which arrives on the Mac as Cmd+Option+Shift, a combination
  that Mac apps rarely bind. They are matched on the physical keys, before the Ctrl→Cmd remap. Each hotkey shows a short toast at the bottom of the window.

  | keys | action |
  |---|---|
  | F11, Alt+Enter, Ctrl+Alt+Shift+F | toggle borderless fullscreen (remembered per monitor) |
  | Ctrl+Alt+Shift+H | toggle the stats overlay (HUD), saved in the config |
  | Ctrl+Alt+Shift+M | cycle the mode fast → hybrid → sharp (`SetMode`; saved, and used for reconnects). Only fast is available if this PC can't decode 4:4:4 |
  | Ctrl+Alt+Shift+K | release the keyboard: the low-level hook is removed, `ReleaseAll` is sent, and keys stay on Windows (Alt+Tab, Win, Alt+F4…). Press again to recapture |
  | Ctrl+Alt+Shift+R | request a keyframe |
  | Ctrl+Alt+Shift+D | disconnect and reconnect immediately (in listen mode, the host redials within about 2 s) |
  | Ctrl+Alt+Shift+A | mute / unmute audio (saved in the config) |
  | Ctrl+Alt+Shift+V | paste files copied in Finder: asks the Mac (`FilePull`) and saves them to `download_dir` |
  | Ctrl+Alt+Shift+X | cancel the running file transfer(s) |
  | Ctrl+Alt+Shift+L | latency test on/off: read the host's test pattern (`glide-probe --pattern-only`) back from the picture; switching it off writes a JSON report to `%TEMP%` ([`docs/LATENCY.md`](../docs/LATENCY.md)) |
  | Ctrl+Alt+Shift+→ / ← | show the next / previous Mac display (left to right), if the Mac has several. Also Glide menu → Show Mac display. The choice is remembered per host and re-selected on reconnect |
  | Ctrl+Alt+Shift+G | relative mouse for games and 3D apps: the pointer is hidden and held in the window, and raw mouse motion goes to the Mac as deltas (`MouseDelta`, PROTOCOL.md §3.6). Press again, or leave the window, to exit. Needs a host that sends `InputCaps` |
  | Ctrl+Alt+Shift+Space | open the Glide menu at the mouse pointer |

  While the window has focus and the keyboard is captured, a low-level keyboard hook sends Win, Alt+Tab, Alt+Space and similar keys to the host.
  To leave the window, click outside it, press Ctrl+Alt+Shift+K, or press Ctrl+Alt+Del, which cannot be intercepted
  (keys held at that moment are released on the Mac when the secure desktop takes the keyboard).
- **Input details** (PROTOCOL.md §3, §3.6). With a host that sends `InputCaps`:
  - Scrolling keeps its source: a notched wheel arrives as Mac line scrolling (3 lines per notch), a precision
    touchpad or high-resolution wheel as smooth pixel scrolling with gesture phases. *Natural scrolling* reverses both.
  - Caps Lock and Num Lock stay with Windows (the PC's LEDs stay right) and their state is sent to the Mac.
    With Num Lock off, keypad keys are Home/End/arrows/… on the Mac too.
  - Play/pause, next, previous and stop go to the Mac. Volume and mute keys stay on this PC, where the Mac's sound plays.
  - Older hosts get the previous messages (`MouseWheel`, `Key`), and the keys behave as before.
- **Connection bar and Glide menu.** A slim tab at the top center of the window shows the host name, like the Microsoft Remote Desktop or Jump connection bar.
  - **Showing it:** move the mouse to the top edge (about 4 px) of the middle third of the window. This works windowed and fullscreen. The corners are excluded, so reaching for the Mac's menu bar there doesn't trigger it.
  - **Hiding it:** it hides 1.5 s after the mouse leaves. *Pin connection bar* keeps it visible, and the pin is saved as `bar_pinned`.
  - While the mouse is over the tab, mouse input is not sent to the Mac. While a mouse button is held (a drag on the Mac), the bar neither appears nor captures input.
  - **Opening the menu:** click the tab and the native Glide menu opens below it. Ctrl+Alt+Shift+Space opens the same menu at the pointer. Menus use dark mode when Windows apps are in dark mode.
  - **Menu items:**
    - Stream mode ▸ Fast / Hybrid / Sharp.
    - Mac display ▸ Automatic / Crisp / Retina / Smooth / Don't change, plus a "Now: 1920×1080 Retina" line. This uses `SetDisplayPreference` / `DisplayInfo` (PROTOCOL.md §3.3), applies for the current session, and is disabled for hosts that don't send `DisplayInfo`.
    - Send to Mac ▸ Spotlight (Cmd+Space), Mission Control (Ctrl+Up), App switcher (Cmd+Tab), Force Quit (Cmd+Opt+Esc), Lock screen (Ctrl+Cmd+Q), Screenshot (Cmd+Shift+5).
    - Toggles: Mute audio, Clipboard sync, Stats overlay, Fullscreen, Release keyboard, Pin connection bar.
    - Input ▸ Ctrl as Command (Win as Control), Natural scrolling, Relative mouse (games, 3D). The first two are saved
      (`ctrl_as_cmd`, `natural_scrolling`).
    - Actions: Refresh picture, Reconnect, Disconnect/Connect, Send files… (disabled until file transfer lands), Settings… (opens `config.json`).
  - **Clipboard sync** can be switched at runtime and is saved as `"clipboard"`. Off means the clipboard listener is removed and nothing is sent or applied; the next ClientHello also stops advertising clipboard support. Turning it on during a session that started with it off reconnects once, to negotiate it.
  - **System menu:** the main items are also in the window's system menu (title-bar right-click, or Alt+Space while the keyboard is released): Glide menu…, Stream mode ▸, Mute audio, Stats overlay, Fullscreen, Refresh picture, Reconnect, Settings….
- **Stats HUD** (off by default): a small translucent panel in the top-left corner. It shows:
  - host name;
  - fps, decode ms and RTT;
  - Mbps and the video size and codec;
  - the mode and the current layer (4:2:0/4:4:4), with sharp and rect frame counts;
  - the view size, the decoder, and the Mac's display mode and preference;
  - audio latency and underruns, or "muted".

  The text is rasterized with GDI into a texture only when it changes (at most twice a second) and blended 1:1, so it stays crisp.
  The window title now shows only `<host> — Glide`; the stats moved to the HUD.
- **Audio** (protocol §3.2): the Mac's sound plays on this PC's default output device. On by default; `--no-audio`
  turns it off (the viewer then doesn't advertise it, so the host doesn't even capture audio).
  - **Ctrl+Alt+Shift+A**, the tray menu or the window menu's *Mute audio* mutes/unmutes. The host stops sending while
    muted. Mute is saved in the config (`audio_muted`), so it persists across reconnects and restarts. Config `"audio": false` is the same as `--no-audio`.
    (The audio branch's Ctrl+F11 was dropped to keep all viewer hotkeys on Ctrl+Alt+Shift; Cmd+F11 now reaches the Mac.)
  - Uncompressed 48 kHz stereo PCM (1.5 Mbit/s), WASAPI shared mode, event-driven, on an MMCSS "Pro Audio" thread.
    A jitter buffer primes to 30 ms and holds it against clock drift with a tiny (≤0.2 %) resample only when it
    leaves a ±8 ms band; underruns raise the target 10 ms (max 120 ms, decays back); more than target + 60 ms
    is dropped, so latency stays bounded.
  - Switching the Windows default output device moves playback within ~1 s; a device error reopens it.
  - The stats HUD (Ctrl+Alt+Shift+H) shows `audio N ms` (estimated host capture → speaker, from the ping clock sync), underruns, or "muted".
  - Tuning (environment): `GLIDE_AUDIO_TARGET_MS` (jitter target, default 30), `GLIDE_AUDIO_FILL_MS` (audio kept
    queued in the device, default 16), `GLIDE_AUDIO_LOWLAT=1` (IAudioClient3 minimum engine period, if the device
    supports one below 10 ms; the CORSAIR headset doesn't).
- Modifier remap (on by default; turn it off with `--no-ctrl-as-cmd`): Ctrl → Command, Win → Control, Alt → Option.
- When a key is held, its typematic repeats are sent as repeated `Key down=1` messages.
- **Clipboard sync** (PROTOCOL.md §5; off with `--no-clipboard`): text and images, both directions,
  while connected to a host that answers caps bit 8 with `ClipboardCaps`.
  - Only changes made while connected are sent; connecting doesn't push either clipboard.
  - PC → Mac: CF_UNICODETEXT (CRLF → LF) if there is text, else the registered "PNG" format, else
    CF_DIB converted to PNG on a worker thread. Mac → PC: CF_UNICODETEXT (LF → CRLF), or
    "PNG" + CF_DIB (translucent pixels composited over white in the DIB).
  - Max 16 MiB per clipboard; bigger content is not sent (logged, never truncated). Received
    images are checked (PNG signature, IHDR ≤ 64 Mpx) before decoding.
  - Content that password managers mark private (`ExcludeClipboardContentFromMonitorProcessing`,
    `Clipboard Viewer Ignore`, `CanIncludeInClipboardHistory`/`CanUploadToCloudClipboard` = 0)
    is not sent unless `--clipboard-sync-secrets` (or `GLIDE_CLIPBOARD_SYNC_SECRETS=1`) is given.
    This moves to `%APPDATA%\Glide\config.json` once that lands.
  - Echo suppression: our own writes are recognized by `GetClipboardSequenceNumber()` / clipboard
    owner, plus a content hash, so nothing ping-pongs.

- **File transfer** (PROTOCOL.md §6; off with config `"file_transfer": false`), while connected to
  a host that sent `FileCaps`:
  - Drop files/folders from Explorer on the window (`DragAcceptFiles`/WM_DROPFILES), or Glide menu →
    *Send files to the Mac…* / *Send folder to the Mac…* (`IFileOpenDialog`, multi-select) → sent to
    the Mac's `~/Downloads/Glide`. Folders are sent recursively; symlinks/junctions are skipped (a
    toast says so). The UIPI message filter is never relaxed: if the viewer runs elevated, Windows
    blocks drops from a normal Explorer and a toast points to the menu's pickers instead.
  - The Glide menu also has *Receive files copied on the Mac* (= Ctrl+Alt+Shift+V), *Cancel file
    transfer* (only while one runs) and *Open received files folder*.
  - Ctrl+Alt+Shift+V pulls what was copied in Finder; the Mac's *Send Files to Viewer…* pushes.
    Files go to `download_dir` (default `<Downloads>\Glide`, the real Downloads known folder),
    with sanitized names, never overwriting (`a (2).txt`), verified by SHA-256 before the rename,
    and marked with Mark-of-the-Web (`Zone.Identifier`, ZoneId=3). Nothing is opened.
  - A toast line shows progress; Ctrl+Alt+Shift+X or the tray's *Cancel file transfer* cancels.
    When files arrive, a tray notification appears: clicking it selects them in Explorer (tray →
    *Open received files folder* does the same later).
  - Chunks go through `Sender::send_bulk`: they yield to every pending input/control message, so
    keys and mouse never wait behind more than one 256 KiB chunk.

The GUI command for the real host (run it in the interactive desktop session, e.g. from a shortcut):

```
%USERPROFILE%\glide\glide-client.exe
```

On first run the setup dialog asks for the Mac's address (or leave it empty and let the Mac connect).
With the default config and no address this listens on port 7420. Then pair: on the Mac choose Glide →
*Pair New Viewer…* (or `glide-host --pair`), then confirm the code on both screens.

### Headless modes (these work over SSH in session 0)

- `--audio-selftest [SECONDS]` opens the default output device exactly like the viewer and runs the real render path
  on **digital silence** (inaudible) for N seconds (default 3). It prints JSON with the output devices, the mix format,
  engine event cadence, device queue, `device_starved` (device ran dry) and jitter-buffer underruns.

- `--probe` prints JSON with:
  - the decoder MFTs (HEVC, H.264, AV1),
  - the D3D11 video decoder profiles and the output formats each supports,
  - whether the HEVC MFT accepts a Main 4:4:4 input type,
  - real decodes of the embedded clips (Main, Main10, RExt 4:4:4 8-bit and 10-bit, RExt 4:2:2 10-bit, H.264), with CPU readback statistics,
  - `hevc444_decode` and a `verdict`.
- `--bench N` connects, decodes for N seconds and prints one JSON line. The fields are:
  - frames, fps, keyframes, bytes, mbps;
  - `decode_ms` for the base layer (decode + copy, timed to GPU completion);
  - `layers`, which holds base and sharp frame counts, `sharp_decode_ms`, `rect_frames`, `avg_rects` and rect area %;
  - `rtt_ms`;
  - `e2e_capture_to_decoded_ms`, estimated from the ping/pong clock offset and counting base-layer frames only (refresh and sharp frames are excluded);
  - `audio`: format, frames, lost frames, and `capture_to_arrival_ms` for audio frames (null if the host sent no audio);
  - `latency`: `host_timing` (the host sends `FrameTiming`, PROTOCOL.md §3.4), `breakdown` (distributions of every
    stage: capture → callback, encode, network, queue, decode, capture → decoded; see `docs/LATENCY.md`) and `clock`
    (min RTT, drift ppm);
  - errors.
- `--clipboard-selftest` exercises the real Win32 clipboard path (apply, read back, CRLF, PNG/DIB,
  echo suppression, external changes) on hidden windows and prints one line per check. Session 0
  has its own clipboard, so running it over SSH doesn't touch the desktop user's clipboard.
- Test hooks for the viewer. The ones that answer dialogs, dump captures or act for the user
  (`GLIDE_PAIR_CONFIRM`, `GLIDE_PROMPT_DUMP`, `GLIDE_SETUP_ANSWER`, `GLIDE_SETUP_DUMP`, `GLIDE_CONNS_DUMP`, `GLIDE_DUMP_FRAME`,
  `GLIDE_DUMP_MENU`, `GLIDE_TEST_ACTIONS`, `GLIDE_TEST_SEND_FILES`) only work in a build with the
  `test-hooks` cargo feature (`cargo build --release --features test-hooks`); a normal build ignores them
  and says so once at startup, so a variable left set (for example with `setx`) can never confirm a
  pairing by itself.
  - `GLIDE_EXIT_AFTER=SECONDS` closes the window automatically and prints stats.
  - `GLIDE_DUMP_FRAME=path.bmp` writes the last rendered frame.
  - `GLIDE_OFFSCREEN=1` forces offscreen rendering. This is automatic in session 0, where no swap chain can be created.
  - `GLIDE_TEARING=1` presents with `ALLOW_TEARING`.
  - `--latency-test` / `GLIDE_LATENCY_TEST=1` starts in latency test mode (Ctrl+Alt+Shift+L); `GLIDE_LATENCY_OUT=path`
    sets where the report goes (default `%TEMP%\glide-latency-<time>.json`). Offscreen (session 0) it measures up to
    `Present()`; scan-out times need a real swap chain.
  - `GLIDE_CONFIG_DIR=dir` uses another config folder. Use it for tests, so the real `%APPDATA%\Glide` is never touched.
  - `GLIDE_TEST_ACTIONS=mode,keyframe,hud,fullscreen,keyboard,reconnect,pullfiles,cancelfiles` fires those hotkey actions one at a time, every `GLIDE_TEST_ACTIONS_MS` (default 1500 ms).
  - `GLIDE_TEST_SEND_FILES=C:\a.bin;C:\folder` sends these to the host once it sent `FileCaps` (drag & drop can't be scripted over SSH). Point `download_dir` into a test folder (config in `GLIDE_CONFIG_DIR`).
  - `GLIDE_PAIR_CONFIRM=yes|no` answers the pairing dialog once its confirm button is enabled (about 1.3 s; and the `--bench` console prompt); `GLIDE_PROMPT_DUMP=x.bmp` captures the dialog first.
  - `GLIDE_NO_TRAY=1` skips the tray icon.

## Testing without the Mac host

```sh
../tools/make_streams.sh                       # 2560x1440 HEVC 4:2:0 / 4:4:4 / H.264 test streams in tools/streams/
python3 ../tools/mock_host.py --port 7421 --pair 300   # listen mode (client dials in); pairing window open 5 min
python3 ../tools/mock_host.py --connect 192.168.1.60:7421 --once   # dial a `--listen 7421` client
# --pair-confirm yes|no|ask: the mock "Mac" answer to a pairing code (ask = type the PC's code);
# --v1-host: behave like an old v1 host; key/paired list in tools/.mock-host-key, .mock-paired.json
```

The mock host:
- picks its stream from the client's caps and mode, and streams at 60 fps;
- answers Ping with Pong and sends a synthetic cursor;
- logs input messages;
- handles RequestKeyframe and SetMode;
- with `--switch-every N`, sends periodic VideoConfig switches to exercise decoder reset;
- clipboard (§5): logs every Clipboard the viewer sends; `--clip-text TEXT` / `--clip-png FILE` push a
  clipboard ~2 s after connect (`--clip-every N` repeats), `--clip-bounce` sends each received
  clipboard back once (the viewer must keep it as is and not echo it), `--clip-save DIR` keeps PNGs;
  `--selftest` checks the codec against the §5 reference bytes;
- file transfer (§6, viewer caps bit 11): sends FileCaps and saves files from the viewer into `--file-recv DIR`
  (verifying SHA-256, never overwriting); `--file-send PATH…` offers files ~2 s after connect, `--file-pull PATH…`
  answers Ctrl+Alt+Shift+V, `--file-evil` sends adversarial offers (traversal, absolute paths, device names, `:`
  streams, bidi tricks, bad SHA-256, 1 PiB, file/folder clash) and logs what the viewer did, `--log-pings` logs how
  long each Ping queued (input priority during uploads), `--file-vectors OUT` regenerates
  `docs/file-transfer-vectors.json`;
- in hybrid mode, sends SharpLayerConfig, then each `--hybrid-period` frames (default 60) a 4:4:4 sharp IDR,
  followed by base frames limited to small rects;
- latency (§3.4): after the viewer's `LatencyEnable` it follows every frame with a `FrameTiming` and logs the
  viewer's `LatencyReport`s; `--latency-pattern` (needs ffmpeg with libx265) streams a live-encoded block-code clock
  pattern (`--pattern-size 1280x720`, `--pattern-cell 8`) instead of the files, for checking `--latency-test`
  against ground truth offline (`docs/LATENCY.md`);
- if the viewer advertises audio, streams a continuous 440 Hz sine at -12 dBFS (`--audio-freq`, `--audio-db`,
  `--no-audio`). A pure tone makes every glitch audible. `--audio-burst 1024` mimics ScreenCaptureKit's buffer
  size, `--audio-drift-ppm` a fast/slow host clock, `--audio-jitter-ms` random send delays, `--audio-pattern 2000:1000`
  gaps like the Mac sends while silent.
