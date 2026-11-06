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
| `src/annexb.rs`, `src/bench.rs` | Annex-B access-unit splitting, and the headless benchmark driver. |
| `src/win/` | Windows only: `d3d` (device + DXGI device manager), `decoder` (MF decoder MFT), `render` (shaders, swap chain), `app` (window, input, cursor, fullscreen), `cursor`, `probe`, `bench_decoder`. |
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
glide-client.exe <host[:port]> [--password PW] [--mode fast|sharp|hybrid] [--no-ctrl-as-cmd] [--bench SECONDS] [--probe]
glide-client.exe --listen [PORT] [same options]
```

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
- Viewer keys: **F11** or **Alt+Enter** toggles borderless fullscreen. These two keys are not sent to the host.
  While the window has focus, a low-level keyboard hook sends Win, Alt+Tab, Alt+Space and similar keys to the host.
  To leave the window, click outside it, or press Ctrl+Alt+Del, which cannot be intercepted.
- Modifier remap (on by default; turn it off with `--no-ctrl-as-cmd`): Ctrl → Command, Win → Control, Alt → Option.
- When a key is held, its typematic repeats are sent as repeated `Key down=1` messages.

The GUI command for the real host (run it in the interactive desktop session):

```
set GLIDE_PASSWORD=...        (PowerShell: $env:GLIDE_PASSWORD="...")
C:\Users\me\glide\glide-client.exe --listen 7420
```

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
- Test hooks for the viewer:
  - `GLIDE_EXIT_AFTER=SECONDS` closes the window automatically and prints stats.
  - `GLIDE_DUMP_FRAME=path.bmp` writes the last rendered frame.
  - `GLIDE_OFFSCREEN=1` forces offscreen rendering. This is automatic in session 0, where no swap chain can be created.
  - `GLIDE_TEARING=1` presents with `ALLOW_TEARING`.

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
- in hybrid mode, sends SharpLayerConfig, then each `--hybrid-period` frames (default 60) a 4:4:4 sharp IDR,
  followed by base frames limited to small rects.
