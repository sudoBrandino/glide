# Glide Windows client (`glide-client.exe`)

Rust viewer for the Glide remote desktop: it decodes HEVC/H.264 with Media Foundation on the
GPU through D3D11, renders through a flip-model swap chain, and forwards keyboard and mouse input.
The wire protocol is defined in `../docs/PROTOCOL.md`.

## Layout

| path | what |
|---|---|
| `src/protocol.rs`, `src/crypto.rs` | Message codec, handshake, KDF, ChaCha20-Poly1305 record layer. Works on any OS and is unit-tested against `../docs/test-vectors.json`. |
| `src/net.rs` | TCP (NODELAY), shared encrypted writer, receive thread, 1 Hz ping, RTT and clock offset. Includes `--listen` reverse mode. |
| `src/hid.rs` | Set-1 scancode → USB HID usage table, plus the Ctrl↔Cmd / Win↔Control remap. Unit-tested. |
| `src/config.rs`, `src/hotkeys.rs`, `src/hud.rs` | Config file (load/save/migration, CLI-vs-config precedence, per-monitor window placement), hotkey table, stats-HUD text. Pure Rust, unit-tested. |
| `src/clipboard.rs` | Clipboard sync logic without Win32: CRLF↔LF, echo guard, DIB↔PNG (`png` crate). Unit-tested. |
| `src/annexb.rs`, `src/bench.rs` | Annex-B access-unit splitting, and the headless benchmark driver. |
| `src/win/` | Windows only: `d3d` (device + DXGI device manager), `decoder` (MF decoder MFT), `render` (shaders, swap chain, text panels), `app` (window, input, cursor, fullscreen, hotkeys), `clipboard` (clipboard listener/apply), `cursor`, `probe`, `bench_decoder`, `dpapi` (saved password), `prompt` (password dialog), `placement` (monitors), `tray`. |
| `res/`, `build.rs` | Icon, manifest (themed controls, PerMonitorV2), password dialog and version info, linked into the exe: MinGW `windres` for the GNU target, `rc.exe` (via `embed-resource`) for MSVC. Regenerate the icon with `../tools/make_icon.py`. |
| `assets/` | Small clips embedded in the exe for `--probe`. Regenerate them with `../tools/make_streams.sh --clips-only`. |

## Build (on macOS, cross-compiling)

```sh
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"   # or ~/.cargo/bin
cargo test                                                    # native unit tests, including the test vectors
cargo build --release --target x86_64-pc-windows-gnu          # needs x86_64-w64-mingw32-gcc (Homebrew mingw-w64)
scp target/x86_64-pc-windows-gnu/release/glide-client.exe my-pc:C:/Users/me/glide/glide-client.exe
```

`.cargo/config.toml` sets the MinGW linker and `+crt-static`. The exe needs only system DLLs.
Shaders are compiled at runtime with `D3DCompile` from `d3dcompiler_47.dll`, which ships with Windows.

## Run

```
glide-client.exe                               (uses the config file: listen on 7420 by default)
glide-client.exe <host[:port]> [--password PW] [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd] [--no-clipboard] [--clipboard-sync-secrets] [--bench SECONDS] [--probe]
glide-client.exe --listen [PORT] [same options]
glide-client.exe --forget-password
```

### Config file and saved password

Settings live in `%APPDATA%\Glide\config.json` (set `GLIDE_CONFIG_DIR` to use another folder). The file
is created on first run and rewritten when settings change. Edit it by hand, or use the tray icon → *Open config file*.

```json
{
  "version": 1,
  "listen_port": 7420,      // used when "host" is null: wait for glide-host --connect
  "host": null,             // "mac.local:7420" = dial the Mac instead
  "mode": null,             // "fast" | "hybrid" | "sharp"; null = auto (hybrid if 4:4:4 decodes)
  "ctrl_as_cmd": true,
  "hud": false,             // stats overlay, toggled with Ctrl+Alt+Shift+H
  "clipboard": true,        // clipboard sync with the host (false = --no-clipboard)
  "clipboard_sync_secrets": false,  // also send clipboard items password managers mark private (= --clipboard-sync-secrets)
  "last_monitor": "\\.\DISPLAY1",
  "windows": { "\\.\DISPLAY1": { "x": 0, "y": 0, "w": 2400, "h": 1400, "maximized": false, "fullscreen": true, "mon_w": 3840, "mon_h": 2160 } }
}
```

(The real file is plain JSON, without comments.)

- **Precedence:** command-line flags win over the config file.
  - A positional `host`, then `--listen [PORT]`, then the config's `host`, then listening on `listen_port`.
  - `--mode` wins over `"mode"`, which wins over auto.
  - `--no-ctrl-as-cmd` / `--ctrl-as-cmd` win over `"ctrl_as_cmd"`.
  - `--no-clipboard` wins over `"clipboard"`.
- **Password:** `--password`, then `GLIDE_PASSWORD`, then the saved password, then a password dialog.
  - The dialog has a *Remember on this PC* box, on by default.
  - The saved password is `password.dpapi` next to `config.json`. It is encrypted with DPAPI (`CryptProtectData`, current user), so only this Windows account on this PC can read it.
  - If the host rejects a saved or typed password, the dialog appears again. Passwords from `--password` or `GLIDE_PASSWORD` are not re-prompted, and they are never saved.
  - Cancel on the first dialog exits. `--forget-password`, or the tray menu, deletes the saved password.
  - Migration: a plaintext `"password"` key in `config.json` is moved into `password.dpapi` and removed from the file on the next start. Older key names (`port`, `listen`, `connect`, `no_ctrl_as_cmd`) are also migrated.
- **Window:** the window placement is remembered per monitor: the position, the size, and whether it is maximized or fullscreen.
  - At startup the window reopens on the last monitor it was on, in the same state.
  - If that monitor is gone, it uses the saved state of the monitor under the cursor, or opens centered.
  - A saved rect that no longer fits (for example after a resolution change) is clamped into the monitor's work area.
- **Tray icon:** Connect / Disconnect / Reconnect, Stats overlay, Open config file, Forget saved password, Quit.
  - *Disconnect* also stops listening, so the host can't reconnect until you choose *Connect*.
  - Left-click brings the window to the front.

To replace a `.cmd` launcher that sets `GLIDE_PASSWORD`, run `glide-client.exe` with no arguments (or with
`--listen 7420`). Enter the password once in the dialog with *Remember* checked.

- **The viewer survives disconnects.** The window opens right away and shows a centered status line, for example
  "Waiting for host on port 7420…".
  - In `--listen` mode it goes back to listening after every disconnect. In connect mode it retries every 2 s.
  - While disconnected, the last picture stays on screen, dimmed, under a status line such as "Connection lost — …" or "Authentication failed — …".
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
- The password comes from `--password`, then the `GLIDE_PASSWORD` environment variable, then a prompt with echo off.
- `--listen [PORT]` is reverse connect. It binds `0.0.0.0:PORT` (default 7420) and accepts the host's
  connection (`glide-host --connect PC:PORT`). The GUI viewer accepts again after each disconnect; `--bench` accepts only once. The protocol is unchanged: the viewer still sends `ClientHandshake` first.
  Use this mode when the firewall blocks PC → Mac. The Windows Firewall rule on the PC allows only
  `C:\Users\me\glide\glide-client.exe` from 192.168.50.4, so keep the exe at that path.
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

  While the window has focus and the keyboard is captured, a low-level keyboard hook sends Win, Alt+Tab, Alt+Space and similar keys to the host.
  To leave the window, click outside it, press Ctrl+Alt+Shift+K, or press Ctrl+Alt+Del, which cannot be intercepted.
- **Stats HUD** (off by default): a small translucent panel in the top-left corner. It shows:
  - host name;
  - fps, decode ms and RTT;
  - Mbps and the video size and codec;
  - the mode and the current layer (4:2:0/4:4:4), with sharp and rect frame counts;
  - the view size and the decoder.

  The text is rasterized with GDI into a texture only when it changes (at most twice a second) and blended 1:1, so it stays crisp.
  The window title now shows only `<host> — Glide`; the stats moved to the HUD.
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

The GUI command for the real host (run it in the interactive desktop session, e.g. from a shortcut):

```
C:\Users\me\glide\glide-client.exe
```

With the default config this listens on port 7420. On first run it asks for the password once (*Remember* on).
`GLIDE_PASSWORD` / `--password` still work for scripting.

Then start the host on the Mac: `mac/.build/release/glide-host --password-file .dev/password --connect 192.168.10.212:7420`.

### Headless modes (these work over SSH in session 0)

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
  - errors.
- `--clipboard-selftest` exercises the real Win32 clipboard path (apply, read back, CRLF, PNG/DIB,
  echo suppression, external changes) on hidden windows and prints one line per check. Session 0
  has its own clipboard, so running it over SSH doesn't touch the desktop user's clipboard.
- Test hooks for the viewer:
  - `GLIDE_EXIT_AFTER=SECONDS` closes the window automatically and prints stats.
  - `GLIDE_DUMP_FRAME=path.bmp` writes the last rendered frame.
  - `GLIDE_OFFSCREEN=1` forces offscreen rendering. This is automatic in session 0, where no swap chain can be created.
  - `GLIDE_TEARING=1` presents with `ALLOW_TEARING`.
  - `GLIDE_CONFIG_DIR=dir` uses another config folder. Use it for tests, so the real `%APPDATA%\Glide` is never touched.
  - `GLIDE_TEST_ACTIONS=mode,keyframe,hud,fullscreen,keyboard,reconnect` fires those hotkey actions one at a time, every `GLIDE_TEST_ACTIONS_MS` (default 1500 ms).
  - `GLIDE_PROMPT_AUTOFILL=pw` fills in the password dialog and presses Connect. `GLIDE_PROMPT_AUTOFILL_RETRY` is used for later prompts, `GLIDE_PROMPT_REMEMBER=1` ticks the box, and `GLIDE_PROMPT_DUMP=x.bmp` captures the dialog.
  - `GLIDE_NO_TRAY=1` skips the tray icon.

## Testing without the Mac host

```sh
../tools/make_streams.sh                       # 2560x1440 HEVC 4:2:0 / 4:4:4 / H.264 test streams in tools/streams/
GLIDE_PASSWORD=... python3 ../tools/mock_host.py --port 7421          # listen mode (client dials in)
GLIDE_PASSWORD=... python3 ../tools/mock_host.py --connect 192.168.10.212:7421 --once   # dial a `--listen 7421` client
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
- in hybrid mode, sends SharpLayerConfig, then each `--hybrid-period` frames (default 60) a 4:4:4 sharp IDR,
  followed by base frames limited to small rects.
