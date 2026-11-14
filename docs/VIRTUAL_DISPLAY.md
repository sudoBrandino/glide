# Virtual display

Glide can create a **virtual display** on the Mac whose resolution matches the viewer, and stream
it instead of the physical screen. A headless Mac, or a Mac whose own screen doesn't match the
viewer, then streams pixel-perfect without BetterDisplay or an HDMI dummy plug. For example:

| Viewer monitor | Display-mode policy | Virtual display |
| --- | --- | --- |
| 3840×2160 | Automatic (4K → Retina) | looks like 1920×1080, HiDPI, 3840×2160 px |
| 3840×2160 | Automatic, "More Space" | looks like 2560×1440, HiDPI, 5120×2880 px (downscaled to 3840 by the encoder) |
| 3840×2160 | Crisp | 3840×2160 at 1x |
| 2560×1440 | Automatic | 2560×1440 at 1x |
| 2560×1440 | Retina | looks like 1280×720, HiDPI, 2560×1440 px |
| 3440×1440 | Automatic | 3440×1440 at 1x (no physical mode list to fit) |

It is **off by default**. Turn it on with the menu bar (**Virtual Display ▸ Use a Virtual Display
Sized to the Viewer**) or in `host.json`.

## Configuration

`~/Library/Application Support/Glide/host.json`:

```json
"virtualDisplay": {
  "enabled": false,
  "lifetime": "session",
  "keepAliveSeconds": 30,
  "makeMain": false,
  "refreshRate": 60
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Master switch. |
| `lifetime` | `"session"` | `"session"`: created when a viewer connects. `"always"`: created at launch and kept while Glide runs (headless Macs). |
| `keepAliveSeconds` | `30` | After a disconnect, keep the display this long, so a reconnect does not reshuffle windows. `0` removes it at once. |
| `makeMain` | `false` | Make it the main display (menu bar, Dock, new windows) while it exists. |
| `refreshRate` | `60` | Panel refresh rate in Hz (24–240). If macOS refuses it, Glide falls back to 60. Glide's capture rate is still capped by `--fps` / `GLIDE_FPS`, so for 120 Hz set both. |
| `width`, `height` | unset | Fixed panel size in pixels instead of the viewer's size. Also the size an always-on display starts with; without it, an always-on display starts at 1920×1080 and resizes when a viewer connects. |

HiDPI or 1x follows the existing **Display Mode** policy (`"display"` in `host.json`, the menu, or
the viewer's per-session choice): Crisp gives a 1x panel at the viewer's size, Retina a HiDPI panel
whose pixels match the viewer, Smooth a HiDPI panel that looks like two-thirds of the viewer, and
Automatic picks Crisp, or the "Automatic on 4K Viewers" choice for 4K-class viewers. "Don't Change"
gives a new display the Automatic mode once and never changes it afterwards. No protocol messages
were added: the viewer's existing `ViewSize` and `SetDisplayPreference` drive it.

## How it fits in

- `GlideCore/VirtualDisplayPolicy.swift` holds the pure logic, which `glide-selftest` unit-tests:
  - `VirtualDisplayPlan`: the mode for a viewer size and preference, and the limits fixed at creation.
  - `VirtualDisplayLifecycle`: when the display exists (the keep-alive state machine).
  - `VirtualDisplayConfig`: parses `host.json`.
- `CGlideVirtualDisplay` is a small Objective-C target that wraps the private classes (see
  "API surface").
- `glide-host/VirtualDisplay.swift` (`VirtualDisplayManager`) creates, re-configures and removes
  the display.
- `ActiveDisplay` prefers the virtual display while it exists, ahead of the `--display` pin and the
  main display. Everything that already follows `ActiveDisplay` therefore follows the virtual display
  without other changes: capture, input mapping, cursor scale and `DisplayModeController`. It is just
  another `CGDirectDisplayID`, and per-session display selection can treat it like any other display.
- `DisplayModeController` hands the policy for the virtual display to `VirtualDisplayManager`. It
  never calls `CGConfigureDisplayWithDisplayMode` on the virtual display (see "Lifecycle").

Sequence on connect:

1. The viewer authenticates.
2. `DisplayModeController.sessionBegan` calls `VirtualDisplayManager.sessionBegan`.
3. If the physical display was switched by an earlier session, its mode is restored first.
4. The virtual display is created with one mode for this viewer, and Glide waits until it is online
   (4 s at most).
5. `ActiveDisplay.current()` now returns it, and capture starts on it.

If anything fails, the error is logged and Glide serves the physical or main display as before.

On a `ViewSize` change or a preference change, Glide re-applies the display's settings with the new
single mode, without destroying the display. It only re-creates the display when the viewer has
outgrown the pixel limits set at creation. Those limits are sized for every style at the viewer's
size, so a crisp, Retina or Smooth switch never re-creates it. The session re-captures on the
screen-parameters notification. If macOS posts none within 1.5 s, Glide posts one itself.

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

The descriptor uses a fixed, non-zero identity:

- vendor `0x676C`, product `0x7664`, serial `1`, name "Glide Virtual Display";
- per Chromium's test utility, macOS 14 wants a non-zero vendor ID and a serial number;
- a stable identity is one "monitor" to macOS, so it remembers the arrangement between sessions;
- macOS stores one ICC profile for it in `/Library/ColorSync/Profiles/Displays` (one file, because
  the identity never changes).

## macOS versions and risks

- **Versions.** The classes ship in CoreGraphics and back Sidecar and AirPlay-to-Mac style
  displays. Open-source projects use them on macOS 11 to 26:
  - DeskPad;
  - force-hidpi (macOS 14+);
  - go-macos/virtualdisplay (tested on 26.6);
  - Chromium's display tests.

  Glide requires macOS 14 anyway. On this development Mac (macOS 27.3), all four classes and every
  selector Glide uses are present.
- **It is private API.** It can change or disappear in any macOS update, and an App Store build
  could not use it (Glide is not on the App Store). Glide only uses it when you opt in, checks it at
  runtime, and falls back to the physical display.
- **The creating process can't see its own display's modes.** `CGDisplayCopyAllDisplayModes` and
  `CGDisplayCopyDisplayMode` return nothing for a virtual display in the process that created it
  (go-macos/virtualdisplay; other processes see the modes normally). So Glide does not choose the
  mode from a mode list. It asks for exactly one mode, so macOS has nothing else to pick:
  - Crisp: `hiDPI = 0` with the viewer's pixel size.
  - HiDPI: `hiDPI = 1` with the looks-like size in points, and pixel limits at least twice that.
    force-hidpi relies on the same behavior: macOS renders the single mode at 2x.

  Glide then reads what macOS actually did through AppKit (`NSScreen` frame and
  `backingScaleFactor`), captures at that size, and logs if it differs from the plan. `ActiveDisplay.mode(of:)`
  serves that mode to capture, cursor scaling, `DisplayInfo` and the menu.
- **A mode switch pins the display.** If its mode is ever changed with `CGDisplaySetDisplayMode` or a
  display-configuration transaction, macOS keeps the display until the creating process exits, even
  after the object is released (go-macos/virtualdisplay). Glide therefore never switches the virtual
  display's mode. It only re-applies the display's own settings. If the display is still online 4 s
  after release, Glide logs it; quitting or restarting Glide removes it. A mode change in
  System Settings by hand has the same effect.
- **Unverified on real hardware in this change.** The self-test below checks the HiDPI start mode,
  re-applying settings, removal on release, and ScreenCaptureKit visibility on the owner's Mac. Run
  it before relying on the feature.

## Lifecycle

The display exists while the `CGVirtualDisplay` object lives. Releasing the object (Glide's
`-invalidate`) removes it, asynchronously. It always disappears when the process exits or crashes,
because WindowServer reclaims it. A Glide crash never leaves a phantom monitor behind. If the system
ends the display itself (for example a WindowServer restart), the termination handler tells Glide,
which falls back to the physical display and creates a new one at the next session.

`VirtualDisplayLifecycle` (unit-tested) decides when the display exists:

- **Session.** A viewer connects → create. The viewer disconnects → keep it for `keepAliveSeconds`.
  A reconnect within that time reuses the display, so windows stay put. When the time runs out, it is
  removed. A timer from an earlier disconnect is ignored after a reconnect.
- **Always on.** Created at launch, kept when viewers disconnect. A connecting viewer resizes it.
- **Menu changes take effect at once.** Enabling it mid-session creates the display, and the session
  re-captures onto it. Disabling it removes the display, and the session re-captures the physical
  display. **Remove Virtual Display Now** removes it while no viewer is connected.
- **Quit** (menu) puts the arrangement back and removes it.

## HiDPI and refresh rates

- `hiDPI = 1` makes macOS advertise Retina variants (half the point size at the same pixels) and
  render a single mode at 2x when the pixel limits allow it. Glide sets the limits
  (`maxPixelsWide/High`) to the largest backing any style needs for this viewer: 5120×2880 for a 4K
  viewer, which leaves room for Smooth. Crisp uses `hiDPI = 0`, so the larger limits can't turn it
  into a 2x mode.
- **Refresh rates.** `CGVirtualDisplayMode` takes any rate. Open-source users run 60 Hz by default
  and 120 Hz optionally. Higher rates make WindowServer composite more often: force-hidpi measures
  about twice the GPU load at 120 Hz on a mirrored display. If `applySettings:` refuses the rate,
  Glide retries at 60 Hz.
- `sizeInMillimeters` is set to about 110 points per inch of the looks-like size, like a desktop
  monitor at its default scale. It only affects the size System Settings shows and similar cosmetic
  details, because Glide always sets the mode explicitly.

## Permissions

Creating a virtual display needs no TCC permission and no entitlement in a non-sandboxed app. Glide
Host is not sandboxed. Capturing it needs Screen Recording, which Glide already has. Input injection
into it uses the existing Accessibility grant: `CGEvent` positions are global coordinates, and
`InputInjector` maps onto `CGDisplayBounds` of the captured display.

## ScreenCaptureKit

A virtual display is a real display to the window server. It appears in
`SCShareableContent.displays`, and `SCContentFilter(display:…)` captures it like any monitor:
DeskPad, BetterDisplay and force-hidpi all do this. A just-created display can take a moment to
appear in ScreenCaptureKit. `VideoPipeline` retries the shareable-content query for up to 3 s rather
than silently capturing another display. Because CoreGraphics gives the creating process no mode,
`VideoPipeline` takes the pixel size from `ActiveDisplay.mode(of:)`, which is the size AppKit
reports, so a HiDPI virtual display is captured at full backing resolution.

## Mirroring vs extending, and windows

- **Extend (Glide's choice).** The virtual display is an extra monitor next to the physical one. It
  starts empty, and apps and windows stay where they are unless you move them. The cursor can travel
  between the two (the viewer only sees the virtual one).
  - **Make main** (`makeMain`). Glide translates the whole arrangement so the virtual display sits
    at (0,0). That makes it the main display: menu bar, Dock and new windows go there, and relative
    positions are kept. Before removing the display, Glide makes the previous main display main
    again. The change uses `.forSession`, so it never outlives the login session.
  - **Headless Mac.** The virtual display is the only display, so it is main automatically.
- **Mirror (not implemented).** Mirroring the physical display *of* the virtual one would show the
  same desktop on both and avoid any window movement. force-hidpi does this to force HiDPI on M4/M5.
  The physical panel then scales the virtual display's mode, which is wrong for a local user who
  doesn't match the viewer. Undoing the mirror is also another display-configuration transaction.
  This may come later as an option.
- **When it disappears.** macOS treats removal like unplugging a monitor: windows on it move to the
  remaining displays (usually the main one) and may be resized. The main display role returns to a
  physical display. When a display with the same identity comes back, recent macOS versions often
  return windows to it, but not reliably. `keepAliveSeconds` keeps the display through short
  reconnects so this doesn't happen on every network blip.

## Trying it safely

1. Self-test first. It creates a temporary display for about 20 s and removes it. Windows may move
   while it runs. It never captures or listens.

   ```sh
   cd mac && swift build -c release   # add --build-system native with Command Line Tools only
   .build/release/glide-host --virtual-display-selftest            # 4K viewer, 60 Hz
   .build/release/glide-host --virtual-display-selftest --viewer 2560x1440 --hz 120
   ```

   It prints `ok`/`FAIL` for each of these:
   - creation;
   - each mode (Retina, Crisp, Smooth, a smaller viewer, Retina again), as seen by AppKit in the same
     process and by CoreGraphics in a child process (`glide-host --list-display-modes ID`);
   - ScreenCaptureKit visibility, when the binary has Screen Recording;
   - removal on release.

   Ctrl-C at any time removes the display. Please paste the output into an issue if anything fails.
2. Turn on **Virtual Display ▸ Use a Virtual Display Sized to the Viewer** in the menu bar, or set
   `"virtualDisplay": {"enabled": true}` and restart the host, then connect the viewer.
   **Display Mode** chooses HiDPI or 1x as before.

**Backing out:**

- Untick the menu item, or set `"enabled": false`. The display is removed at once and Glide streams
  the physical display.
- If a display ever lingers, quit or restart Glide Host. The display can't outlive the process.
- Arrangement changes from `makeMain` are `.forSession` and end at logout.

## References

- DeskPad (Stengo/DeskPad): descriptor, `hiDPI = 1`, mode list, `CGDisplayStream` capture.
- force-hidpi (sammcj/force-hidpi):
  - a single mode with `hiDPI = 1` and 2x pixel limits renders at 2x;
  - arrangement and mirror transactions;
  - 120 Hz cost.
- go-macos/virtualdisplay: modes not reported to the creating process, mode changes pin the display
  until exit, asynchronous removal, identity and ICC-profile notes.
- Chromium `ui/display/mac/test/virtual_display_util_mac.mm`: a unique serial number and a non-zero
  vendor ID on macOS 14.
