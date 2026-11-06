# Glide

A from-scratch remote desktop for controlling a Mac from Windows, aiming for Jump Desktop-level
quality and responsiveness on a LAN. Native on both ends:

- **`mac/`** — Swift host: ScreenCaptureKit capture → VideoToolbox hardware HEVC (4:2:0
  low-latency, or 4:4:4 "sharp") → ChaCha20-Poly1305 over TCP. CGEvent input injection,
  client-side cursor shapes.
- **`windows/`** — Rust viewer: Media Foundation hardware decode → D3D11 flip-model
  presentation, raw keyboard/mouse capture, host cursor applied as the native Windows cursor.
- **`docs/PROTOCOL.md`** — the wire protocol (normative). `docs/test-vectors.json` +
  `tools/gen_vectors.py` are the reference crypto vectors both sides must reproduce.

## Quick start (dev)

```sh
# Mac host
cd mac && swift build -c release --build-system native
.build/release/glide-selftest ../docs/test-vectors.json      # protocol self-test
.build/release/glide-host --password-file ../.dev/password   # viewer dials the Mac
.build/release/glide-host --password-file ../.dev/password --connect 192.168.10.212   # Mac dials the viewer

# Local end-to-end check (same Mac, exact latency): spins a small test window
.build/release/glide-probe 127.0.0.1 --password-file ../.dev/password --seconds 8 --animate --png /tmp/frame.png
```

See `windows/README.md` for the viewer.

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

Only an authenticated viewer can replace the active session; unauthenticated connections are
capped (4) and closed after 5 s without a valid ClientHello.

> Only one `glide-host` process can capture at a time; a second one's ScreenCaptureKit stream
> is interrupted.

## Measured (M3 Pro host, 2560×1440 @ 60 Hz, same-Mac loopback)

| Config | capture → decoded p50 / p95 |
|---|---|
| HEVC 4:2:0, low-latency RC, 1 frame in flight (default) | 14.8 / 21.9 ms |
| HEVC 4:2:0, normal RC | 12.4 / 37.5 ms |
| H.264 low-latency | 14.5 / 22.0 ms |
| HEVC 4:4:4 ("sharp") | 27.7 / 42.5 ms |
| any config, 2 frames in flight | +10–20 ms (queueing) |

Hardware HEVC 4:4:4 at 4K could not sustain 60 fps on random-noise input (~180 ms); real desktop
content is far cheaper — re-measure.
