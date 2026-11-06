# Glide

A from-scratch remote desktop for controlling a Mac from Windows, aiming for Jump Desktop-level
quality and responsiveness on a LAN. Native on both ends:

- **`mac/`** — Swift host: ScreenCaptureKit capture → VideoToolbox hardware HEVC (4:2:0
  low-latency, or 4:4:4 "sharp") → ChaCha20-Poly1305 over TCP. CGEvent input injection,
  client-side cursor shapes.
- **`windows/`** — Rust viewer: Media Foundation hardware decode → D3D11 flip-model
  presentation, raw keyboard/mouse capture, host cursor applied as the native Windows cursor.
- **Audio**: Mac system audio (ScreenCaptureKit, on the same capture stream) → 48 kHz stereo PCM →
  WASAPI on the PC through a drift-correcting jitter buffer (protocol §3.2). `GLIDE_NO_AUDIO=1`
  disables it on the host, `--no-audio` on the viewer.
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
