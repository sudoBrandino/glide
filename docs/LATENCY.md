# Latency: instrumentation, ground truth, tuning

This document describes how Glide measures its end-to-end latency, what was measured offline, and
how to run the live glass-to-glass test. The wire format is in [`PROTOCOL.md`](PROTOCOL.md) §3.4.

## What is measured

Each video frame gets timestamps at every stage of the pipeline. The host stamps its stages with
its own clock and sends them to the viewer in a `FrameTiming` message (0x81) right after the
frame. The viewer adds its own stamps and joins the two sets by `frame_id`. Host times are
converted to viewer time with the Ping/Pong clock estimate (see [Clock sync](#clock-sync)).

| Stage | From → to | Clock | Where it is stamped |
|---|---|---|---|
| `cap_to_callback` | SCK frame PTS → our capture callback runs | host | `VideoPipeline.stream(_:didOutputSampleBuffer:)` |
| `callback_to_submit` | callback → frame handed to the encoder (encoder busy, backpressure) | host | `VideoPipeline.pump()` |
| `encode` | encoder submit → VideoToolbox output callback | host | `VideoPipeline.pump()` callback |
| `host` | capture → encoded (sum of the three above) | host | — |
| `encoded_to_sent` | encoded → network stack accepted the whole record | host | `Session` (`send` completion) |
| `network` | host enqueued → viewer received and decrypted the record | synced | viewer receive thread |
| `queue` | received → decode start (render thread busy, batching) | viewer | render thread |
| `decode` | decode start → decoded (CPU side, GPU work may still be queued) | viewer | render thread |
| `render` | decoded → `Present()` call (canvas update, frame-latency wait) | viewer | render thread |
| `scanout` | `Present()` → the vblank at which that present reached the screen | viewer | DXGI frame statistics |
| `total` | capture → scan-out (capture → `Present()` when scan-out is unknown) | synced | — |

Notes:
- **Capture time.** The capture time is ScreenCaptureKit's presentation timestamp, which is the
  host clock (`CLOCK_UPTIME_RAW`, the same clock as `mach_absolute_time` and
  `CACurrentMediaTime`). It is the time the WindowServer composited the frame. The time between an
  app drawing something and that composite isn't in `total`. The test pattern measures it (see
  [Glass-to-glass ground truth](#glass-to-glass-ground-truth)).
- **Scan-out time.** `scanout` comes from `IDXGISwapChain::GetFrameStatistics`. The vblank time
  of present *P* is `SyncQPCTime + (PresentRefreshCount − SyncRefreshCount) × period`, taken when
  the statistics report `PresentCount == P` (the same counter as `GetLastPresentCount`). The
  refresh period is measured from successive statistics samples, with the monitor's nominal rate
  as a fallback. A present that DXGI never reports, because a newer present replaced it within
  the same refresh, is finalized after 300 ms without a scan-out time and counted in
  `presents_not_shown`. The vblank time is the top of the screen. A pixel at row *y* is scanned
  out `y / height × period` later; the test pattern sits at the top.
- **Excluded frames.** Refresh frames (flag bit1) are excluded, as before. Sharp-layer frames
  are kept in the full report but left out of the HUD window.
- **No offscreen scan-out.** In session 0 or offscreen there is no swap chain, so there is no
  scan-out time. `total` then ends at `Present()`.

### Clock sync

`net::ClockSync` changed from "the all-time lowest-RTT sample" to a **sliding-window minimum-RTT
estimate with drift tracking**:

- The viewer pings at 2 Hz (it sent 1 Hz before), plus 8 pings 50 ms apart right after connecting.
- The window is 30 s, split into 5 s buckets, and only each bucket's fastest exchange is used.
  Queueing only ever adds delay, so the fastest exchanges carry the least asymmetry. The error
  bound is ± min RTT / 2.
- Once at least four bucket minima span 20 s or more, a least-squares line through them tracks
  the drift between the two crystals. A bucket whose best exchange was still slow is dropped from
  the fit, and a slope beyond ±100 ppm counts as noise. When no fit is possible, the estimate
  anchors on the best recent exchange and keeps the last fitted drift.
- The old estimator never updated its best sample, so it drifted without bound. At 40 ppm, it
  was 2.4 ms off after one minute and 144 ms off after an hour.
- The unit test `clock_sync_tracks_drift_with_sliding_window` simulates a host clock 7 s ahead
  that runs 40 ppm fast or 25 ppm slow, with 0–2 ms random queueing on each leg, over four random
  seeds. The estimate stays within 100 µs, and the drift estimate is within 5 ppm.
- Measured Mac ↔ PC through an SSH tunnel: min RTT 3.2–3.4 ms and drift 4.7 ppm over a 30 s
  fit, and 37 ppm on another run while the fit still used a 10 s span. That noise led to the
  stricter fit rules above. The tunnel adds RTT and jitter. The real LAN RTT is lower, so the
  error bound there is tighter.

## Where the numbers show up

**Viewer HUD (Ctrl+Alt+Shift+H).** A new line shows the p50 over the last 2 s:

```
lat p50  enc 10.2  net 1.3  dec 0.2  scan 6.9  glass 21.6 ms
```

- `enc` is capture → encoded (host).
- `net` is enqueued → received.
- `dec` is decode.
- `scan` is `Present()` → scan-out.
- `glass` is capture → scan-out. Without frame statistics, the label is `→present` instead.

In latency test mode, a second line shows the ground truth.

**Viewer → host.** Every 2 s the viewer sends a `LatencyReport` (0x82) with its p50s:

- The host log has a line every 5 s:
  `latency: capture->callback p50 … p95 …, callback->encode …, encode p50 … p95 …; viewer n=… p50 ms: host … net … queue … decode … render … scanout … total(glass) …`.
- The menu bar has a row: `Latency: capture→callback 4.2 · encode 10.4 · glass ~27 ms`.

**`glide-client --bench N`.** The JSON gains a `latency` object:

- `host_timing`
- `breakdown`, with a distribution (`n`, `p5`, `p50`, `p95`, `max`, `mean`) for every stage
- `clock`: `min_rtt_ms`, `drift_ppm`, `window_samples`

Bench frames finish at "decoded" (the bench decoder waits for GPU completion).

**`glide-probe`.** On the Mac, over loopback, the probe sends `LatencyEnable` and prints the
host's per-stage p50/p95, including the network stage, which is exact because both ends share a
clock. With `--pattern`, it also reads the test pattern back from its own decoded frames:
pattern clock → decoded on the same Mac.

## Glass-to-glass ground truth

The breakdown is only as good as its instrumentation. The latency test checks it against a
measurement that doesn't depend on it.

1. **Draw the clock on the host.** A test pattern draws the host clock into the picture as a
   machine-readable block code: `glide-probe --pattern-only` on the Mac, or
   `mock_host.py --latency-pattern` offline.
2. **Read it back on the viewer.** In latency test mode (`--latency-test`,
   `GLIDE_LATENCY_TEST=1`, or **Ctrl+Alt+Shift+L**), the viewer copies the pattern's region of the
   decoded canvas into a staging texture after each present that showed new frames:
   - It first does a full-canvas search, at most twice a second until the pattern is found.
     After that it reads a 60×3-cell strip.
   - It maps the strip a few milliseconds later without stalling the render thread.
   - It decodes the clock value and records the **first present that showed each value**:
     pattern clock → `Present()` call, and pattern clock → vblank.
3. **Report.** When the test is switched off, or the viewer exits, the viewer writes a JSON
   report with distributions of every stage plus `ground_truth`:
   - `to_present`
   - `to_scanout`
   - `minus_instrumented_to_present`: the ground truth minus the instrumentation's
     capture → present for the same present

   The report goes to `%TEMP%\glide-latency-<unix time>.json`, or to `GLIDE_LATENCY_OUT`.

**Block code.** The layout is shared by `windows/src/blockcode.rs`,
`mac/Sources/GlideCore/BlockCode.swift` and `tools/mock_host.py`:

- **Cells.** One row of 56 square cells, white = 1 and black = 0, on a black quiet zone at
  least 2 cells wide:
  - 8-bit sync `10110010`
  - 32-bit `value` (MSB first)
  - 4-bit `kind`
  - 4-bit `counter`
  - CRC-8/SMBUS (poly 0x07, init 0) over `[value big-endian, kind << 4 | counter]`
- **Size.** The pattern is 60 × 4 cells: a black row, a code strip 2 cells tall, and another
  black row. Glide-probe uses 8-pt cells (480 × 32 pt).
- **Value.** `value` holds the low 32 bits of a host time in µs. The viewer restores the high
  bits from its own clock estimate.
- **Finding it.** The decoder finds the sync by run lengths, so the pattern can be anywhere on
  screen. It handles cell sizes from 2.5 to 64 px and survives blur and noise.
- **Reference vector.** Value `0x12345678`, kind 1, counter 5 encodes as
  `10110010000100100011010001010110011110000001010100111111`. All three implementations test
  this vector.

**Kinds and what they measure:**

| `kind` | value = | ground truth measures | expected vs. instrumented `total` |
|---|---|---|---|
| 1 `target` (default) | `CADisplayLink.targetTimestamp`: when the frame is due on the host display | display → viewer screen | ≈ 0 if the SCK PTS is the composite time (checks the capture timestamp itself) |
| 0 `draw` (`--pattern-kind draw`) | the time the app drew | app draw → viewer screen | + compositor wait, 0–16.7 ms at 60 Hz (hypothesis b) |
| 2 `frame` | the mock host's frame generation time, the same instant as `capture_time_us` | mock "capture" → viewer | exactly 0: checks the frame-id join and the clock conversion |

## Offline evidence

These runs used only the mock host and offline tools. Nothing touched the live host or the
user's desktop.

### Viewer pipeline and ground-truth reader

The setup:

- `tools/mock_host.py --latency-pattern` ran on the Mac. It live-encodes the block-code pattern
  with x265 in `ultrafast`/`zerolatency` mode, in software, at 60 fps.
- `glide-client.exe` (this branch) ran on the PC from `C:\Users\me\glide\dev\latency\` in
  session 0, through `ssh -R`.
- The PC decodes on the RTX 5070 Ti through the Media Foundation HEVC hardware decoder.
- The SSH tunnel adds about 3 ms of RTT, so `network` here is tunnel time, not LAN time.
- Session 0 has no swap chain, so these runs are offscreen and there is no scan-out time.

| Run | capture → encoded (x265 sw) | network | queue | decode (CPU side) | render | capture → present p50 / p95 | ground truth → present p50 / p95 (n) | ground truth − instrumented |
|---|---|---|---|---|---|---|---|---|
| GUI `--latency-test`, 1280×720, 25 s | 10.2 | 1.46 | 0.01 | 0.18 | 0.01 | 11.9 / 13.2 | 11.9 / 13.0 (1458 of 1466 frames) | p5/p50/p95 = 0.0 / 0.0 / 0.0 |
| GUI `--latency-test`, 2560×1440, 30 s | 15.7 | 1.38 | 0.01 | 0.18 | 0.01 | 17.5 / 28.8 | 17.5 / 28.2 (1751 of 1762 frames) | 0.0 / 0.0 / 0.0 |
| `--bench 10`, 1280×720 (decoder waits for the GPU) | 9.3 | 1.38 | 0.01 | 1.38 | — | capture → decoded 12.2 / 15.2 | — | — |

All values are p50 in ms unless noted.

- **The pipeline is verified.** Ground truth equals the instrumentation for every frame. This
  confirms the frame-id join, the `FrameTiming` transport, the clock conversion, the
  readback → decode path on a real GPU canvas, and "first present showing the value"
  de-duplication.
- **The reader is reliable.** The pattern is found within about 0.5 s of the first frame, and
  more than 99% of the presents yield a code.
- **CPU decode time is not GPU decode time.** The viewer's `decode` stage is about 0.2 ms
  because Media Foundation returns before the GPU finishes. The bench decoder waits for GPU
  completion, which takes about 1.4 ms at 720p. With a swap chain, the GPU time ends up inside
  `scanout`.

### Encoder (hypothesis c), and a new finding

`glide-host --encode-bench 3` measures encode time offline:

- It feeds synthetic 2560×1440 text frames (NV12, like the SCK base stream) through the host's
  own `VideoEncoder`.
- Settings: HEVC 4:2:0, 44 Mbps auto bitrate, one frame in flight, M3 Pro.
- It never touches ScreenCaptureKit or the network.
- It was run while the live session was idle (under 3 fps). Values are from three runs.

| Scenario | Normal RC: encode p50 / p95 (ms) | Low-latency RC: encode p50 / p95 (ms) |
|---|---|---|
| Full-screen text scroll @ 60 fps | 10.4–10.6 / 11.5 (20 KB/frame) | 13.7–14.1 / 14.6 (3.7 KB/frame) |
| Typing (one cell changes) @ 60 fps | 10.4–10.5 / 11.7 (17 KB/frame) | 14.0–14.3 / 14.6 (0.7 KB/frame) |
| Isolated frames @ 20 fps | 10.3–11.2 / 11.2–13.1 | 13.3–14.5 / 13.5–16.4 |
| Isolated frames @ 5 fps | **19.4–21.5** / 19.8–22.2 | 15.0–17.8 / 16.4–22.7 |
| Isolated frames @ 2 fps | **18.8–21.3** / 19.3–22.9 | 15.2–19.0 / 16.5–21.1 |
| @ 2 fps, **PTS spaced 1/60 s** (frame counter) | **11.2–11.6** / 13.7–14.2 (45.0 KB, vs 44.5 KB with wall-clock PTS) | — |
| @ 2 fps, `RealTime = false` | 12.3–13.1 / 13.5–14.2 | — |
| @ 2 fps + a tiny 256×256 session encoding at 30 or 60 Hz ("keep warm") | 18.8–21.6 (no effect) | — |

**Low-latency rate control loses.** At 2560×1440 it is about 3.5 ms *slower* than normal RC at
60 fps and spends 5–25× fewer bits, so the picture is softer. When frames are sparse it beats
wall-clock normal RC, but it never beats normal RC with counter PTS. Keep normal RC as the
default.

- `Encoder.swift` already defaults to normal RC (`GLIDE_LL=1` opts in). The README table
  said "low-latency RC … (default)"; that row predated the switch and has been corrected.

**New finding: sparse frames encode about 9 ms slower.**

- Interactive use is bursty: one keystroke produces one frame after an idle period. With the
  wall-clock PTS the host used, such an isolated frame takes about 20 ms to encode instead of
  about 10.5 ms.
- This matches the live host log, which reported encode p50 17.0–17.9 ms while sending
  0.4–14 fps.
- It is not media-engine clocking: a parallel keep-warm session doesn't help. VideoToolbox's
  real-time mode paces itself by PTS gaps.
- Spacing the PTS as if the frames were consecutive brings the frame back to about 11 ms, with
  the same bits per frame.
- **Change made:** `VideoPipeline` now uses a frame-counter PTS at the nominal rate for both
  encoders. The PTS isn't used for anything else. `GLIDE_PTS=wallclock` restores the old
  behavior for an A/B test. Expected effect on the first frame after idle: about −8 to −9 ms.
  Confirm it in the live run (runbook step 4).

## Tuning hypotheses

| # | Hypothesis | Offline status | How to settle it live |
|---|---|---|---|
| a | SCK `queueDepth` (5) and `minimumFrameInterval` (1/fps) inflate capture → callback | **Needs a live run**: only one SCK capture can run, and it is the user's. New knobs: `GLIDE_SCK_QUEUE_DEPTH=N` (1–8) and `GLIDE_SCK_INTERVAL=native` (no cap). | Compare `latency: capture->callback p50/p95` in the host log, and the HUD `enc`, at queue depth 3, 5 and 8, and with the native interval. Expectation: the callback runs right away (latest-frame-wins never blocks the queue), so depth should barely matter. The interval matters only if the display runs faster than `fps`. |
| b | The 60 Hz virtual display adds an average of about 8.3 ms of compositor wait | Measured offline: the BetterDisplay virtual screen "RustDesktop" offers **only 60 Hz** modes (`CGDisplayCopyAllDisplayModes`), and BetterDisplay stores `refreshRates@VirtualScreen:147 = "[60]"`. The list is configurable in BetterDisplay's virtual screen settings, so 120 Hz is very likely possible, but changing it reconfigures the user's display. **Needs the user's consent and a live run.** | A change at a random time waits uniformly 0–16.7 ms (mean 8.3) for the next composite at 60 Hz, and 0–8.3 ms (mean 4.2) at 120 Hz. Measure ground truth with `--pattern-kind draw --pattern-hz 5` at 60 and at 120 Hz, with the host at `GLIDE_FPS=120` (the default 60 would throttle SCK). Expect about −4 ms on average. At 120 fps of continuous motion, a 10.5 ms encode with one frame in flight caps throughput at about 95 fps, and latest-frame-wins drops the rest. |
| c | Encoder settings at 2560×1440 | **Measured offline** (table above): normal RC is about 10.5 ms and low-latency RC about 14 ms. Isolated frames cost about 20 ms with wall-clock PTS and about 11 ms with counter PTS, which is now the default. | Live A/B of `GLIDE_PTS=wallclock` against the default, using `--pattern-hz 2` (isolated frames). The host log's `encode p50` and the viewer `enc` should drop by about 8 ms. Optionally try `GLIDE_LL=1`. |
| d | Viewer present path: waitable swap chain with max frame latency 1, and `ALLOW_TEARING` (`GLIDE_TEARING=1`) in fullscreen | Instrumented, but **needs a live run**: present statistics need a real swap chain on the interactive desktop. The session-0 test viewer has none. | The HUD `scan` and the report's `present_to_scanout`, in three configurations: windowed, fullscreen (F11), and fullscreen with `GLIDE_TEARING=1`. Expectations at 144 Hz (6.94 ms period): **windowed, DWM-composed**: wait for the next composition (0–6.9 ms, mean 3.5) plus one frame, so about 10 ms. **Fullscreen with independent flip**: about 3.5 ms (half a period). **With tearing**: about 0–1 ms. With G-SYNC/VRR in independent flip, expect about 0 ms. Check `refresh_hz_measured` in the report. |

## Live glass-to-glass runbook (for the lead, with the user's consent)

All steps keep the live session usable. Every host restart drops the viewer for about 2 s, and
the viewer reconnects on its own.

### 0. Deploy (once)

1. Merge `feat/latency` and build the host:

   ```sh
   cd mac && swift build -c release --build-system native && .build/release/glide-selftest ../docs/test-vectors.json
   cd .. && tools/make-host-app.sh && tools/install-host.sh
   ```

   `install-host.sh` restarts the LaunchAgent.
2. Build the viewer (`cargo build --release --locked --target x86_64-pc-windows-gnu`).
3. Deploy the viewer to the **same path** as today (`C:\Users\me\glide\glide-client.exe`) with
   the rename trick, so the firewall rule keeps applying. The user then restarts the viewer
   (`Glide.cmd`).

### 1. Instrumentation sanity check (no pattern)

1. The user presses **Ctrl+Alt+Shift+H** and moves a window around for about 10 s. The HUD shows
   `lat p50  enc …  net …  dec …  scan …  glass … ms`.
2. On the Mac, the host log should show the viewer's report:

   ```sh
   grep 'latency:' ~/Library/Logs/glide-host.log | tail -3
   ```

   The lines include `viewer n=… total(glass) …`. The menu bar shows a `Latency:` row.
3. If `scan` shows `–` and the label says `→present`, frame statistics aren't arriving. Note it,
   and the `present_info` in the report says whether the viewer is offscreen.

### 2. Ground-truth pattern

Run this on the Mac from the lead's shell, which is in the user's GUI session:

```sh
~/Development/glide/mac/.build/release/glide-probe --pattern-only --seconds 600 &   # 480×32-pt strip, top-left
```

The pattern is a borderless, click-through window at status-bar level, below the menu bar. Tell
the user it's there. `kill %1` removes it.

### 3. Measure

Each run is 60 s. The user presses **Ctrl+Alt+Shift+L** to start and again to stop. The toast
shows the report path: `C:\Users\me\AppData\Local\Temp\glide-latency-<t>.json`. Fetch it:

```sh
ssh my-pc 'cmd /c type C:\Users\me\AppData\Local\Temp\glide-latency-<t>.json'
```

| Run | Condition | Look at |
|---|---|---|
| A | Windowed viewer, default host, continuous pattern | `ground_truth.to_scanout`, `total_scanout_only`, `minus_instrumented_to_present` (expect ≈ 0 ± 1 ms for kind 1) |
| B | Fullscreen (F11) | `present_to_scanout`: windowed vs. independent flip |
| C | Fullscreen with tearing. The user restarts the viewer with `set GLIDE_TEARING=1` before `Glide.cmd`. | `present_to_scanout` → ~0 |
| D | Pattern updating at 2 Hz: restart the probe with `--pattern-hz 2`. These are isolated frames, like typing. | `host_capture_to_encoded`, `ground_truth` |
| E | Same as D, with `GLIDE_PTS=wallclock` on the host (see step 4) | Expect `encode` about 8 ms higher than D |
| F | `--pattern-kind draw` (continuous, then `--pattern-hz 5`) | `ground_truth − instrumented` = compositor wait (hypothesis b) |

### 4. Host knobs

Host knobs are environment variables for the LaunchAgent:

```sh
launchctl setenv GLIDE_PTS wallclock            # or GLIDE_SCK_QUEUE_DEPTH 3 / GLIDE_SCK_INTERVAL native / GLIDE_LL 1 / GLIDE_FPS 120
launchctl kickstart -k gui/$(id -u)/io.github.sudobrandino.glide.host
grep 'capture:' ~/Library/Logs/glide-host.log | tail -2   # confirms the knob ("encoder PTS = wall clock", "SCK queueDepth …")
# … measure …
launchctl unsetenv GLIDE_PTS && launchctl kickstart -k gui/$(id -u)/io.github.sudobrandino.glide.host
```

For hypothesis (a), compare `latency: capture->callback p50/p95` in the host log at the default,
at `GLIDE_SCK_QUEUE_DEPTH` 3 and 8, and with `GLIDE_SCK_INTERVAL=native`.

### 5. Optional: 120 Hz virtual display (hypothesis b)

Only with the user's explicit OK, because it changes their display:

1. In BetterDisplay, open the "RustDesktop" virtual screen settings and add 120 Hz to its
   refresh rates.
2. Switch to 2560×1440 @ 120 Hz.
3. Run `launchctl setenv GLIDE_FPS 120` and kickstart the host.
4. Repeat runs A and F.
5. Revert afterwards.

### 6. Clean up

```sh
kill %1                                          # pattern window
launchctl unsetenv GLIDE_PTS GLIDE_LL GLIDE_FPS GLIDE_SCK_QUEUE_DEPTH GLIDE_SCK_INTERVAL
launchctl kickstart -k gui/$(id -u)/io.github.sudobrandino.glide.host
```

The user can turn the HUD off with Ctrl+Alt+Shift+H. Latency test mode is off unless
Ctrl+Alt+Shift+L is pressed.

### Mac-only cross-check (optional)

This needs the live host stopped, because it runs a second session. Instead of the PC viewer,
run on the Mac:

```sh
glide-probe 127.0.0.1 --seconds 20 --pattern
```

It prints:
- the host stage p50/p95 from `FrameTiming`
- `ground truth (pattern clock -> decoded)`, exact because both ends share one clock

This step kicks the user's viewer session, so get consent first.

## Limitations

- **CPU-side decode stage.** `decode` covers the CPU side only. GPU decode and conversion time
  lands in `render`/`scanout` with a swap chain, and in nothing at all offscreen. The bench
  decoder waits for the GPU, so the bench `decode` includes it.
- **`network` measures the whole message.** It is measured to "the whole record received and
  decrypted", so for large keyframes it includes transfer time. `encoded_to_sent` is the TCP
  stack accepting the data, not wire time.
- **Present-path dependencies.** Scan-out times need a flip-model swap chain on the interactive
  desktop. With VRR, the "period" is not a fixed refresh, but `PresentRefreshCount −
  SyncRefreshCount` is normally 0, so the vblank time stays valid.
- **Repeated pattern values aren't counted.** The ground truth only counts a pattern value the
  first time a present shows it. If the pattern's region isn't updated in a frame, for example
  because a rect-limited base frame skipped it, the old value is ignored rather than producing
  an inflated latency.
- **Test mode costs a little.** It copies a strip from the canvas after each present, and does a
  full-canvas search at most twice a second until the pattern is found. That is cheap, but it is
  not free, so it is off by default.
