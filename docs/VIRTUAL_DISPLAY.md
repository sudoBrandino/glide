# Virtual display

Glide streams a **virtual display** by default. When a viewer connects, the Mac host creates a
monitor whose pixel size and refresh rate match the viewer, and captures it 1:1. That gives:

- **No downscale.** The Mac renders exactly the pixels the viewer shows. Without it, a Mac driving
  a 4K monitor at "looks like 2304×1296" renders 4608 px wide, and ScreenCaptureKit downsamples
  that to the viewer's 2560.
- **The viewer's refresh rate.** A 120 Hz or 144 Hz viewer gets a 120/144 Hz panel, so a change
  waits about 4 ms on average for the next composite instead of 8 ms at 60 Hz
  ([LATENCY.md](LATENCY.md), hypothesis b).
- **No mode switching of your monitor** to fit the viewer, and no BetterDisplay or HDMI dummy plug
  on a headless Mac.

| Viewer monitor | Display Mode | Virtual display |
| --- | --- | --- |
| 2560×1440 @ 144 Hz | Automatic | 2560×1440 at 1x, 144 Hz |
| 3840×2160 @ 120 Hz | Automatic (4K → Retina) | looks like 1920×1080, HiDPI, 3840×2160 px, 120 Hz |
| 3840×2160 | Automatic, "More Space" | looks like 2560×1440, HiDPI, 5120×2880 px (the encoder scales to 3840) |
| 2560×1440 | Retina | looks like 1280×720, HiDPI, 2560×1440 px |
| 3440×1440 | Automatic | 3440×1440 at 1x |

It uses a private macOS API. If the API is missing or fails, Glide logs why, shows it in the menu
(**Virtual Display ▸ Status**), and streams the physical display as before.

**Opting out:** untick **Virtual Display ▸ Use a Virtual Display Sized to the Viewer** in the menu
bar, or set `"virtualDisplay": {"enabled": false}` in host.json. Glide then streams the Mac's
display and may switch its mode to fit the viewer (the **Display Mode** policy), as before.

## What you see on the Mac

**With a monitor attached** (the default, `whenMonitorAttached: "mirror"`): while a viewer is
connected, your main monitor **mirrors** the virtual display. There is one desktop, at the viewer's
size, and every window, the menu bar and the Dock are on it, so the viewer sees all of them. Your
monitor shows the same picture, scaled; macOS gives it a matching mode while it mirrors. Windows
larger than the viewer's desktop are shrunk to fit when the mirror starts, exactly as when Glide
used to switch your monitor's mode. They are not moved to another screen.

When the viewer disconnects, Glide waits `keepAliveSeconds` (10 s) in case it reconnects, then
ends the mirror, gives your monitor its own mode back, and removes the virtual display. Every
arrangement change is made `.forSession`, so nothing survives logout.

**Without a monitor** (headless, or a laptop with the lid closed and no external display): the
virtual display is the Mac's only screen, so it is the main display by itself. It is kept when the
viewer disconnects, because removing the Mac's only screen would leave it with none.

**If your main monitor already matches the viewer exactly** (same points and pixels, for example a
4K monitor at "looks like 1920×1080" and a 4K viewer on Retina), Glide streams the monitor directly
and creates nothing.

### Why mirroring is the default

| Option | Remote viewer sees | Windows | Your monitor | Verdict |
| --- | --- | --- | --- | --- |
| **(b) Mirror** (default) | every window, menu bar, Dock | stay on the one desktop; shrunk only if larger than the viewer's desktop | shows the session, in a matching mode macOS picks; mode restored afterwards | the remote desktop works as expected |
| (a) Extend + make main | an empty desktop with the menu bar and Dock; your windows stay on the monitor, which the viewer can't see | new windows open on the virtual display; old ones must be moved over blind | untouched | the viewer can't reach existing windows |
| (c) Stream the monitor | everything | untouched | untouched, but captured at its own size (4608 px downscaled) or mode-switched | used automatically when it already matches; otherwise the old path |

Extend (`"extend"`, made main by default) and stream (`"stream"`) are available in the menu and
in host.json.

Sleep: a session keeps the displays awake (as before). When idle, the displays sleep normally.

## Configuration

`~/Library/Application Support/Glide/host.json`. Every key is optional:

```json
"virtualDisplay": {
  "enabled": true,
  "whenMonitorAttached": "mirror",
  "lifetime": "session",
  "keepAliveSeconds": 10
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch. `false` opts out. A `--display N` pin also turns the default off; set `true` explicitly to use both. |
| `whenMonitorAttached` | `"mirror"` | `"mirror"`: the main monitor mirrors the virtual display while a viewer is connected. `"extend"`: the virtual display sits beside your monitors. `"stream"`: no virtual display while a monitor is attached (the old behavior). |
| `makeMain` | `true` | `"extend"` only: make the virtual display the main display (menu bar, Dock, new windows) while it is streamed. |
| `lifetime` | `"session"` | `"session"`: created when a viewer connects, removed `keepAliveSeconds` after it leaves (kept if it is the only display). `"always"`: created at launch and kept; when idle it hides behind your monitor (it mirrors it), so it adds no invisible desktop area. |
| `keepAliveSeconds` | `10` | After a disconnect, keep the streaming arrangement this long, so a quick reconnect changes nothing. `0` = at once. |
| `refreshRate` | unset | Panel refresh rate in Hz (24–240). Unset: the viewer's monitor refresh rate (ClientHello `max_fps`, which the Windows viewer fills from its monitor), else 120 Hz. If macOS refuses the rate, Glide uses 60 Hz. |
| `width`, `height` | unset | Fixed panel size in pixels instead of the viewer's size. |

Glide's capture rate is still capped by `--fps` / `GLIDE_FPS` (default 60). The panel refresh
cuts the compositor wait either way; set `GLIDE_FPS=120` (or more) to also send more frames.

HiDPI or 1x follows the **Display Mode** policy (`"display"` in host.json, the menu, or the
viewer's per-session choice): Crisp gives a 1x panel at the viewer's size, Retina a HiDPI panel
whose pixels match the viewer, Smooth a HiDPI panel that looks like two-thirds of the viewer, and
Automatic picks Crisp, or the "Automatic on 4K Viewers" choice for 4K-class viewers. "Don't
Change" gives a new display the Automatic mode once and never changes it afterwards. No protocol
messages were added: ClientHello (`view_w`, `view_h`, `max_fps`), `ViewSize` and
`SetDisplayPreference` drive it.

The display picker (PROTOCOL.md §3.5) lists it as "Glide Virtual Display", and **Automatic** (the
viewer's `SelectDisplay(0)`, the Mac menu's **Streamed Display ▸ Automatic**) means the virtual
display. A monitor that mirrors it isn't listed, because it shows the same picture. Precedence, in
`ActiveDisplay`: the session's explicit selection, then the virtual display while it is online,
then the `--display` pin, then the main display.

## Lifetime: what macOS really does (macOS 27.3, M3 Pro)

Measured with short-lived displays on the owner's Mac (WindowServer log in brackets):

1. **Releasing the `CGVirtualDisplay` object removes the display at once while any display is
   awake** [`CGXVirtualDisplayDestroy` … `Remove N from the console display set`]. That holds after
   several re-applied settings, HiDPI toggles and child-process mode queries, and after mirroring.
   Process exit (or a crash) removes it the same way.
2. **While every display sleeps, removal is deferred.** WindowServer logs `Deferred hotplugs cannot
   be processed in a non-wake state`, then `CGXVirtualDisplayDestroy … not found`. The display
   stays online, **even after the creating process exits**, until the next display wake, when
   WindowServer removes it. This is what left display 10 behind after the first real-hardware
   self-test: the OMEN was asleep with the lid closed. Waking the displays (any user activity, or
   `caffeinate -u -t 2`) removed displays 10 and 11 at once, without a logout.
3. **Re-applying settings does not pin the display**, and neither do mode queries from another
   process. The older report that a mode switch keeps a display until its process exits
   (go-macos/virtualdisplay) did not reproduce. Glide still never switches the virtual display's
   mode with `CGConfigureDisplayWithDisplayMode`; it only re-applies its own settings.
4. **A second display with the same vendor/product/serial can't be created while a leftover one
   is pending removal** [`CGXVirtualDisplayCreate … no displayID available`]; `initWithDescriptor:`
   returns nil.
5. **When the master of a mirror set is removed, macOS dissolves the set and can leave the former
   slave in a default mode.**

What Glide does about it:

- One display at a time per host process. It is created when a viewer connects, resized by
  re-applying settings within limits of at least 6K (6144×3456 px), so moving the viewer to a
  bigger monitor doesn't re-create it, and kept through `keepAliveSeconds`.
- It is removed only when idle, and **only while a display is awake**. If every display is
  asleep at that moment, Glide takes it out of service (it is no longer streamed or listed) and
  releases it at the next display wake, or reuses it if a viewer connects first.
- Before releasing, Glide always ends the mirror explicitly and restores your monitor's mode. That
  includes Quit, Restart, `SIGTERM` (`launchctl`, install scripts) and `SIGINT`.
- At startup and before creating a display, Glide looks for a leftover Glide display (same
  vendor/product). If one exists, it wakes the displays (a connecting session wakes them anyway),
  waits up to 3 s for macOS to finish the removal, and then uses serial 2 if serial 1 is still
  taken.
- A leftover can only come from a process that exited while every display slept. It is harmless:
  nobody can see it, and it disappears at the next wake, or at logout or reboot.

## Reading the mode back

macOS doesn't always apply single-mode settings exactly as asked, so Glide checks what it got:

- **The creating process gets nothing useful from CoreGraphics or AppKit for its own virtual
  display.** `CGDisplayCopyDisplayMode` and `CGDisplayCopyAllDisplayModes` return nothing, and
  `NSScreen.screens` doesn't list it, even with a run loop. That is why the first real-hardware
  self-test failed its AppKit checks: they were the wrong check, not a broken display. Inside the
  creator, ScreenCaptureKit's `pointPixelScale` also reports 1.0 for a HiDPI virtual display.
- **Other long-running processes are unreliable too.** A process without an AppKit event loop
  gets no mode for a display that appeared after it started. One with `NSApplication.run()` sees
  it, but kept a stale mode after a later re-apply.
- **A fresh process always reports the truth**, and `CGDisplayBounds` (points) is correct
  in-process.
- **The first settings applied to a never-seen identity are sometimes ignored.** macOS picks a
  default instead: 1x at twice the size, or HiDPI for a 1x request. Applying the same settings
  again fixes it.
- `CGDisplayIsOnline` and `CGDisplayIsActive` return **-1** for a removed display ID in some
  processes, so Glide compares with `== 1`, not `!= 0`.

So after every create or re-apply, Glide:

1. polls `CGDisplayBounds` until it shows the planned looks-like size, re-applying the settings
   once after 2 s if it doesn't;
2. reads the pixel size from a child process (`glide-host --list-display-modes ID`, about 100 ms,
   off the main thread);
3. records that mode (`ActiveDisplay.mode(of:)`), which capture, input mapping, cursor scale,
   `DisplayInfo` and the menu use, and posts a screen-parameters notification so the session
   re-captures at that size.

If the child can't run, matching points mean the plan.

## Mirroring: what macOS really does

Measured with two virtual displays standing in for a monitor. The self-test repeats this, and no
physical display is touched:

- Mirroring, un-mirroring and swapping master and slave each work as one display-configuration
  transaction.
- **macOS switches the slave to a mode matching the master.** The master keeps its mode. When the
  mirror ends, macOS gives the slave its *persisted* preferred mode back. That need not be the mode
  it had: a `.forSession` switch, or a new display's first default, is lost. So Glide remembers your
  monitor's mode before mirroring (persisted in host.json `display.restore`, so a crash is covered
  by the startup restore) and puts it back if macOS didn't.
- Settings applied to a mirror slave take effect only once it is master again.

## How it fits in

- `GlideCore/VirtualDisplayPolicy.swift` holds the pure logic, which `glide-selftest` unit-tests:
  - `VirtualDisplayConfig`: host.json and the refresh-rate choice.
  - `VirtualDisplayPlan`: the mode for a viewer, the 6K creation limits, and the "monitor already
    matches" check.
  - `VirtualDisplayLifecycle`: create, resume, standby and destroy.
  - `VirtualDisplayTopology`: mirror, extend or alone.
  - `DisplayModeInfo.parseListing`: the child read-back.
- `CGlideVirtualDisplay` is a small Objective-C target that wraps the private classes (see "API
  surface").
- `glide-host/VirtualDisplay.swift` (`VirtualDisplayManager`) creates, resizes, arranges and
  removes the display, and reads its mode back.
- `ActiveDisplay` prefers the virtual display while it is online. Everything that already follows
  `ActiveDisplay` therefore follows it: capture, input mapping, cursor scale, the multi-monitor
  list and `DisplayModeController`.
- `DisplayModeController` hands the policy for the virtual display to `VirtualDisplayManager`. It
  remembers and restores the mirroring monitor's mode, and never restores a mode on a monitor
  while it mirrors.

Sequence on connect:

1. The viewer authenticates. The session wakes the displays and keeps them awake.
2. `DisplayModeController.sessionBegan` calls `VirtualDisplayManager.sessionBegan(viewerHz:)` with
   ClientHello's `max_fps`.
3. Glide decides whether to use the virtual display at all: not with `"stream"` and a monitor, and
   not if the main monitor already matches the viewer exactly.
4. If a pending mode restore exists, the physical display gets its own mode back first.
5. The display is created (or the kept one is reused). Glide waits until it is online, then reads
   its mode back.
6. The streaming arrangement is set up: the monitor mirrors it, or it extends.
7. `ActiveDisplay.current()` returns it, and capture starts.

If anything fails, the error is logged and shown in the menu, and Glide serves the physical
display.

On a `ViewSize` change or a preference change, Glide re-applies the display's settings with the new
single mode. It doesn't destroy the display, then reads the mode back. It only re-creates the
display when the viewer outgrows the creation limits.

## API surface

The private classes live in `CoreGraphics.framework`. The runtime metadata on macOS 27.3 (read with
`class_copyMethodList`, without creating anything) matches what open-source users declare:

```objc
@interface CGVirtualDisplayDescriptor : NSObject
@property unsigned int vendorID, productID, serialNumber;   // older: serialNum
@property(retain) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(retain) dispatch_queue_t queue;                  // also -setDispatchQueue:
@property(copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)hz;
- (instancetype)initWithWidth:(unsigned)w height:(unsigned)h refreshRate:(double)hz transferFunction:(unsigned)tf;
@property(readonly) unsigned width, height; @property(readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;                               // 0 or 1
@property unsigned int rotation;                            // + refreshDeadline, isReference
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;   // nil if refused
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(readonly) CGDirectDisplayID displayID;
@end
```

Glide does not declare these as `@interface`s. That would link the `_OBJC_CLASS_$_…` symbols, and
dyld would then refuse to launch the host on a macOS that drops them. Instead, `GLDVirtualDisplay.m`:

- declares the selectors in protocols;
- gets the classes with `NSClassFromString`;
- checks every selector with `instancesRespondToSelector:` (`+unavailableReason` explains a
  mismatch);
- wraps each call in `@try`/`@catch`.

`nm` on the built `glide-host` shows no `CGVirtualDisplay` symbols. The target is plain Objective-C
with ARC, so it builds with the Command Line Tools and doesn't need Xcode or private SDK headers.

The descriptor uses a fixed, non-zero identity: vendor `0x676C`, product `0x7664`, serial `1`
(`2` while a leftover holds `1`), and the name "Glide Virtual Display". Chromium's test utility
notes that macOS 14 wants a non-zero vendor ID and a serial number. A stable identity is one
"monitor" to macOS, so it remembers settings between sessions and stores one ICC profile for it in
`/Library/ColorSync/Profiles/Displays`.

## macOS versions and risks

- **Versions.** The classes ship in CoreGraphics and back Sidecar and AirPlay-to-Mac style
  displays. Open-source projects use them on macOS 11 to 26: DeskPad, force-hidpi (macOS 14+),
  go-macos/virtualdisplay, and Chromium's display tests. Glide requires macOS 14. On macOS 27.3,
  all four classes and every selector Glide uses are present, and the self-test passes.
- **It is private API.** It can change or disappear in any macOS update, and an App Store build
  could not use it (Glide is not on the App Store). Glide checks it at runtime and falls back to
  the physical display.
- **Mirroring changes your monitor's mode for the session.** macOS does that, not Glide. Glide
  restores the mode afterwards. Choose `"extend"` or `"stream"` if you don't want it.

## Permissions

Creating a virtual display needs no TCC permission and no entitlement in a non-sandboxed app. Glide
Host is not sandboxed. Capturing it needs Screen Recording, which Glide already has. Input
injection into it uses the existing Accessibility grant: `CGEvent` positions are global
coordinates, and `InputInjector` maps onto `CGDisplayBounds` of the captured display.

## ScreenCaptureKit

A virtual display is a real display to the window server. It appears in
`SCShareableContent.displays` (the self-test checks this in the creating process), and
`SCContentFilter(display:…)` captures it like any monitor. A just-created display can take a moment
to appear in ScreenCaptureKit, so `VideoPipeline` retries for up to 3 s rather than capturing
another display. The capture size comes from `ActiveDisplay.mode(of:)`, the mode Glide read back,
so a HiDPI virtual display is captured at its full backing resolution.

## Self-test

```sh
cd mac && swift build -c release   # add --build-system native with Command Line Tools only
.build/release/glide-host --virtual-display-selftest            # 4K viewer, 60 Hz
.build/release/glide-host --virtual-display-selftest --viewer 2560x1440 --hz 120
```

It takes about 30 s. A worker child creates the displays exactly as the host does, and the parent
observes from outside. It prints `ok`/`FAIL` for:

- creation with Glide's identity and 6K limits;
- each mode (Retina, Crisp, Smooth, a smaller viewer, Retina again): the host's read-back matches
  the plan, and a fresh process reports the same mode;
- ScreenCaptureKit visibility in the creating process;
- mirroring with a stand-in virtual monitor (mirror, swap, unmirror), and the virtual display's own
  settings coming back after it;
- every physical display unchanged before, during and after the test;
- removal on release;
- **nothing lingering after the worker exits.** The worker leaves one display unreleased on
  purpose, like a crash. If something lingers, the test says so, wakes the displays, and reports
  whether that removed it.

The test keeps the displays awake while it runs, because removal is deferred while every display
sleeps. It never captures or listens.

On the owner's Mac (macOS 27.3, M3 Pro, OMEN 32 OLED, lid closed), both
`--viewer 2560x1440 --hz 120` and `--viewer 3840x2160 --hz 60` pass every check. The stand-in's
first settings were ignored once and fixed by the re-apply. In one run macOS restored the
stand-in's persisted mode instead of its previous one, which the test reports as info.

## Backing out

- Untick **Use a Virtual Display Sized to the Viewer**, or set `"enabled": false`. A display in use
  is removed at once, and Glide streams the physical display.
- If a "Glide Virtual Display" ever lingers (only after a host exit while every display slept),
  wake the displays: move the mouse, or run `caffeinate -u -t 2`. Otherwise it goes at logout or
  reboot.
- Arrangement changes are `.forSession` and end at logout. Your monitor's mode is restored when
  the mirror ends (and at the next host start after a crash).

## References

- DeskPad (Stengo/DeskPad): descriptor, `hiDPI = 1`, mode list, `CGDisplayStream` capture.
- force-hidpi (sammcj/force-hidpi): a single mode with `hiDPI = 1` and 2x limits renders at 2x;
  mirroring a physical display of a virtual one; the 120 Hz cost.
- go-macos/virtualdisplay: modes not reported to the creating process, asynchronous removal,
  identity and ICC-profile notes. Its "a mode switch pins the display" did not reproduce on
  macOS 27.3; removal deferred during display sleep did.
- Chromium `ui/display/mac/test/virtual_display_util_mac.mm`: a unique serial number and a non-zero
  vendor ID on macOS 14.
