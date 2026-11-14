import Foundation

// Pure logic for the virtual display (docs/VIRTUAL_DISPLAY.md). The CoreGraphics side lives in
// glide-host/VirtualDisplay.swift; everything here is unit-tested in glide-selftest.

/// What Glide does with the virtual display while a physical monitor is attached
/// (host.json `virtualDisplay.whenMonitorAttached`).
public enum VirtualDisplayMonitorMode: String, CaseIterable, Sendable {
    /// Default. While a viewer is connected the main monitor mirrors the virtual display: one
    /// desktop, every window visible to the viewer, nothing moves between screens.
    case mirror
    /// The virtual display is an extra monitor beside the physical one (made main if `makeMain`).
    case extend
    /// No virtual display while a monitor is attached: stream the monitor (the display-mode policy
    /// may switch its mode, as before). The virtual display is only used when there is no monitor.
    case stream
}

/// host.json `"virtualDisplay"`. Every field is optional; out-of-range numbers are clamped and an
/// unknown string means the default, so a typo in a value never disables the rest of host.json
/// (a wrong JSON type still does, as for every other section).
public struct VirtualDisplayConfig: Codable, Equatable, Sendable {
    /// Master switch (default **true**: the virtual display is Glide's native path).
    public var enabled: Bool?
    /// "session" (default): created when a viewer connects, removed after it leaves (plus
    /// `keepAliveSeconds`) unless it is the Mac's only display. "always": created at launch and kept.
    public var lifetime: String?
    /// Seconds after a disconnect before Glide restores the arrangement and removes the display, so
    /// a reconnect does not reshuffle anything (default 10, 0 = at once, capped at 24 h).
    public var keepAliveSeconds: Double?
    /// "mirror" (default) | "extend" | "stream"; see `VirtualDisplayMonitorMode`.
    public var whenMonitorAttached: String?
    /// "extend" only: make the virtual display the main display (menu bar, Dock, new windows) while
    /// it is streamed (default true).
    public var makeMain: Bool?
    /// Panel refresh rate in Hz (24...240). Unset (default): the viewer's monitor refresh rate from
    /// ClientHello `max_fps`, or 120 Hz if the viewer doesn't say.
    public var refreshRate: Double?
    /// Fixed panel size in pixels, used instead of the viewer's ViewSize (both must be set).
    /// Also the size an always-on display starts with before any viewer has connected.
    public var width: Int?
    public var height: Int?

    public init(enabled: Bool? = nil, lifetime: String? = nil, keepAliveSeconds: Double? = nil, whenMonitorAttached: String? = nil,
                makeMain: Bool? = nil, refreshRate: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.enabled = enabled; self.lifetime = lifetime; self.keepAliveSeconds = keepAliveSeconds
        self.whenMonitorAttached = whenMonitorAttached; self.makeMain = makeMain; self.refreshRate = refreshRate
        self.width = width; self.height = height
    }

    public static let defaultKeepAlive: Double = 10
    public static let defaultSize = (w: 1920, h: 1080)
    /// Refresh rate when neither host.json nor the viewer gives one.
    public static let defaultRefreshRate: Double = 120

    public var isEnabled: Bool { enabled ?? true }
    /// Enabled in host.json explicitly (not just by default). A `--display` pin turns the default off.
    public var explicitlyEnabled: Bool { enabled == true }
    public var alwaysOn: Bool { lifetime?.lowercased() == "always" }
    public var keepAlive: Double { min(max(keepAliveSeconds ?? Self.defaultKeepAlive, 0), 86_400) }
    public var monitorMode: VirtualDisplayMonitorMode {
        whenMonitorAttached.flatMap { VirtualDisplayMonitorMode(rawValue: $0.lowercased()) } ?? .mirror
    }
    public var wantsMain: Bool { makeMain ?? true }
    /// The panel refresh rate: host.json if set, else the viewer's monitor (ClientHello `max_fps`,
    /// 0 = unknown), else 120 Hz. Always 24...240.
    public func refreshRate(viewerHz: Int?) -> Double {
        if let r = refreshRate, r.isFinite { return min(max(r, 24), 240) }
        if let v = viewerHz, v >= 24 { return Double(min(v, 240)) }
        return Self.defaultRefreshRate
    }
    /// The fixed panel size, if both dimensions are sane.
    public var fixedSize: (w: Int, h: Int)? {
        guard let w = width, let h = height, w >= 640, h >= 480, w <= 7680, h <= 4320 else { return nil }
        return (w, h)
    }
}

/// What to ask CGVirtualDisplay for: one mode, in points when `hiDPI` (the compositor renders it
/// at 2x), in pixels otherwise.
public struct VirtualDisplayPlan: Equatable, Sendable, CustomStringConvertible {
    /// Size of the single CGVirtualDisplayMode.
    public var modeWidth: Int
    public var modeHeight: Int
    public var hiDPI: Bool
    public var refreshRate: Double
    /// The concrete style this plan implements (crisp, retina or smooth).
    public var style: DisplayModePreference

    public init(modeWidth: Int, modeHeight: Int, hiDPI: Bool, refreshRate: Double, style: DisplayModePreference) {
        self.modeWidth = modeWidth; self.modeHeight = modeHeight; self.hiDPI = hiDPI; self.refreshRate = refreshRate; self.style = style
    }

    /// The mode macOS should end up in: looks-like size in points, backing size in pixels.
    public var expected: DisplayModeInfo {
        let s = hiDPI ? 2 : 1
        return DisplayModeInfo(width: modeWidth, height: modeHeight, pixelWidth: modeWidth * s, pixelHeight: modeHeight * s, refreshRate: refreshRate)
    }

    public var description: String { "\(style.rawValue) \(expected) @ \(Int(refreshRate.rounded())) Hz" }

    /// Largest backing size the planner produces (wider smooth plans fall back to retina).
    public static let maxBackingWidth = 7680
    public static let maxBackingHeight = 4320
    /// The smallest pixel limits a display is created with ("6K"), so moving the viewer to a bigger
    /// monitor re-applies settings instead of re-creating the display.
    public static let generousLimit = (w: 6144, h: 3456)

    /// The plan for a viewer showing `viewerW` x `viewerH` pixels. `manual` is treated like
    /// `automatic` (a new virtual display needs some mode; Glide just never changes it afterwards).
    public static func make(viewerW: Int, viewerH: Int, preference: DisplayModePreference,
                            highDPIChoice: HighDPIViewerChoice, refreshRate: Double) -> VirtualDisplayPlan? {
        guard viewerW >= 320, viewerH >= 200 else { return nil }
        let vw = min(viewerW, maxBackingWidth) & ~1, vh = min(viewerH, maxBackingHeight) & ~1
        let pref: DisplayModePreference = preference == .manual ? .automatic : preference
        let style = DisplayModePolicy.resolve(pref, viewerW: vw, viewerH: vh, highDPIChoice: highDPIChoice)
        switch style {
        case .retina:
            return VirtualDisplayPlan(modeWidth: (vw / 2) & ~1, modeHeight: (vh / 2) & ~1, hiDPI: true, refreshRate: refreshRate, style: .retina)
        case .smooth:
            // Looks like 2/3 of the viewer's pixels (like DisplayModePolicy's smooth), rendered at 2x
            // and downscaled to the viewer by the encoder.
            let lw = (vw * 2 / 3) & ~7, lh = (vh * 2 / 3) & ~7
            if lw * 2 > maxBackingWidth || lh * 2 > maxBackingHeight {
                return make(viewerW: viewerW, viewerH: viewerH, preference: .retina, highDPIChoice: highDPIChoice, refreshRate: refreshRate)
            }
            return VirtualDisplayPlan(modeWidth: lw, modeHeight: lh, hiDPI: true, refreshRate: refreshRate, style: .smooth)
        default:
            return VirtualDisplayPlan(modeWidth: vw, modeHeight: vh, hiDPI: false, refreshRate: refreshRate, style: .crisp)
        }
    }

    /// The backing size every style (crisp, retina, smooth) needs for this viewer.
    public static func maxPixels(viewerW: Int, viewerH: Int, highDPIChoice: HighDPIViewerChoice, refreshRate: Double) -> (w: Int, h: Int) {
        var w = 0, h = 0
        for p in [DisplayModePreference.crisp, .retina, .smooth] {
            guard let e = make(viewerW: viewerW, viewerH: viewerH, preference: p, highDPIChoice: highDPIChoice, refreshRate: refreshRate)?.expected else { continue }
            w = max(w, e.pixelWidth); h = max(h, e.pixelHeight)
        }
        return (w, h)
    }

    /// maxPixelsWide/High for a new display: every style for this viewer, and at least 6K, so the
    /// one display Glide keeps serves later viewers and style changes by re-applying settings.
    public static func creationLimits(viewerW: Int, viewerH: Int, highDPIChoice: HighDPIViewerChoice) -> (w: Int, h: Int) {
        let need = maxPixels(viewerW: viewerW, viewerH: viewerH, highDPIChoice: highDPIChoice, refreshRate: 60)
        return (min(max(need.w, generousLimit.w), maxBackingWidth), min(max(need.h, generousLimit.h), maxBackingHeight))
    }

    /// Whether this plan can be applied to a display created with these limits.
    public func fits(maxPixelsWide: Int, maxPixelsHigh: Int) -> Bool {
        expected.pixelWidth <= maxPixelsWide && expected.pixelHeight <= maxPixelsHigh
    }

    /// Physical size reported to macOS, in millimetres: ~110 points per inch, like a typical
    /// desktop monitor at its default scale. Mostly cosmetic (System Settings, font smoothing).
    public var sizeInMillimeters: (w: Double, h: Double) {
        (Double(modeWidth) * 25.4 / 110, Double(modeHeight) * 25.4 / 110)
    }

    /// A physical display already in exactly this mode (same points and pixels) can be streamed
    /// 1:1 without a virtual display or any mode switch.
    public func matches(_ physical: DisplayModeInfo?) -> Bool {
        physical.map { $0.sameSize(expected) } ?? false
    }
}

/// When the virtual display exists. Pure state machine; the host feeds it events and performs the
/// returned action. Times are seconds on any monotonic clock. `onlyDisplay`: the virtual display is
/// the Mac's only display (headless or lid closed without a monitor), so it is never removed when
/// idle. `wanted`: a virtual display is wanted with the displays online now
/// (`VirtualDisplayTopology.wantsVirtual`: false with "stream" and a monitor attached), which
/// overrides always-on.
public struct VirtualDisplayLifecycle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No display.
        case off
        /// A viewer is connected and using it.
        case inUse
        /// The viewer left; idle at `until` unless one reconnects.
        case lingering(until: Double)
        /// Kept with no viewer (always-on, or the Mac's only display); arrangement restored.
        case standby
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Create it. Once it is online, `created()` says what to set up.
        case create
        /// It exists: size it for the connecting viewer and set up the streaming arrangement.
        case resume
        /// It is still being created (always-on at launch, or a re-create): the creation sets up
        /// the arrangement for the phase at that time (`created()`) and answers the viewer.
        case awaitCreation
        /// Restore the Mac's arrangement, keep the display.
        case standby
        /// Restore the Mac's arrangement, then remove the display.
        case destroy
        /// Call `timerFired(now:onlyDisplay:wanted:)` at this time.
        case scheduleTimer(at: Double)
    }

    /// What a creation that just finished sets up. Decided when it finishes, not when it started:
    /// a viewer may have connected (or left) meanwhile.
    public enum Ready: Equatable, Sendable {
        /// A viewer uses it: the streaming arrangement.
        case streaming
        /// No viewer: hidden behind the main monitor (or alone).
        case standby
        /// The viewer left while it was created; the keep-alive timer decides.
        case keep
        /// Not wanted any more: remove it.
        case discard
    }

    public private(set) var phase: Phase = .off
    public private(set) var sessionActive = false
    public private(set) var enabled = false
    public private(set) var alwaysOn = false
    public private(set) var keepAlive: Double = VirtualDisplayConfig.defaultKeepAlive
    /// A create is in flight (between `.create` and `created()` / `lost()`).
    public private(set) var creating = false
    /// Resumes in flight (`.resume`: arranging and sizing the existing display for a viewer, until
    /// its mode is read back): connecting viewers are answered when they finish, not before.
    public private(set) var resuming = 0
    /// Displays changed while a create was in flight: re-evaluated once it finishes
    /// (`takeDisplaysChangedDuringCreate`), not dropped.
    public private(set) var displaysChangedDuringCreate = false

    /// Owed answers to connecting viewers can be given now: no create or resume is in flight
    /// (each answers them itself when it finishes).
    public var mayAnswer: Bool { !creating && resuming == 0 }

    public init(enabled: Bool = false, alwaysOn: Bool = false, keepAlive: Double = VirtualDisplayConfig.defaultKeepAlive) {
        self.enabled = enabled; self.alwaysOn = alwaysOn; self.keepAlive = keepAlive
    }

    public var exists: Bool { phase != .off }

    /// The host started.
    public mutating func launched(wanted: Bool = true) -> Action {
        guard enabled, alwaysOn, wanted, phase == .off else { return .none }
        phase = .standby
        creating = true
        return .create
    }

    public mutating func sessionBegan(wanted: Bool = true) -> Action {
        sessionActive = true
        guard enabled else { return .none }
        guard wanted else { return off() }  // "stream" with a monitor: this session streams the monitor
        let wasOff = phase == .off
        phase = .inUse
        if wasOff { creating = true; return .create }
        if creating { return .awaitCreation }
        resuming += 1
        return .resume  // lingering/standby: reuse it (no window reshuffle)
    }

    /// The host resumes the existing display for a viewer (`.resume`, or a creation that reused a
    /// display and found a viewer waiting).
    public mutating func resumeStarted() { resuming += 1 }

    /// A resume finished (its mode is read back) or was superseded.
    public mutating func resumeFinished() { resuming = max(0, resuming - 1) }

    /// Whether displays changed during the create that just finished (and forgets it): the host
    /// then re-runs its display-change handling with the displays online now.
    public mutating func takeDisplaysChangedDuringCreate() -> Bool {
        defer { displaysChangedDuringCreate = false }
        return displaysChangedDuringCreate
    }

    public mutating func sessionEnded(now: Double, onlyDisplay: Bool, wanted: Bool = true) -> Action {
        sessionActive = false
        guard phase == .inUse else { return .none }
        if keepAlive > 0 {
            phase = .lingering(until: now + keepAlive)
            return .scheduleTimer(at: now + keepAlive)
        }
        return idle(onlyDisplay: onlyDisplay, wanted: wanted)
    }

    /// A timer scheduled earlier fired. Stale timers (a viewer came back, or a newer linger
    /// started) are ignored.
    public mutating func timerFired(now: Double, onlyDisplay: Bool, wanted: Bool = true) -> Action {
        guard case let .lingering(until) = phase, now >= until - 0.05 else { return .none }
        return idle(onlyDisplay: onlyDisplay, wanted: wanted)
    }

    /// The creation finished (the display is online and its mode read back).
    public mutating func created() -> Ready {
        creating = false
        switch phase {
        case .inUse: return .streaming
        case .standby: return .standby
        case .lingering: return .keep
        case .off: return .discard
        }
    }

    /// The host re-creates the display (the viewer outgrew its limits): the phase stays.
    public mutating func recreating() {
        guard phase != .off else { return }
        creating = true
    }

    /// Displays were added, removed or rearranged (a monitor plugged in, the lid opened). An idle
    /// display that is no longer the only one and isn't always-on is removed; an always-on one
    /// re-hides behind the (new) main monitor; "stream" with a monitor removes an idle one. A
    /// connected viewer keeps it.
    public mutating func displaysChanged(onlyDisplay: Bool, wanted: Bool = true) -> Action {
        guard enabled else { return .none }
        // Decided once the create finishes, with the displays online then (a monitor plugged in
        // mid-create must still remove an idle "stream" display).
        if creating { displaysChangedDuringCreate = true; return .none }
        switch phase {
        case .standby:
            if onlyDisplay || (alwaysOn && wanted) { return .standby }
            return off()
        case .lingering:
            return wanted || onlyDisplay ? .none : off()
        case .off:
            guard alwaysOn, wanted, !sessionActive else { return .none }
            phase = .standby
            creating = true
            return .create
        case .inUse:
            return .none
        }
    }

    private mutating func idle(onlyDisplay: Bool, wanted: Bool) -> Action {
        if onlyDisplay || (alwaysOn && wanted) {
            phase = .standby
            return creating ? .none : .standby  // a creation in flight sets up standby itself
        }
        return off()
    }

    private mutating func off() -> Action {
        creating = false
        resuming = 0
        displaysChangedDuringCreate = false
        guard phase != .off else { return .none }
        phase = .off
        return .destroy
    }

    /// Settings changed (menu or host.json).
    public mutating func configure(enabled: Bool, alwaysOn: Bool, keepAlive: Double, onlyDisplay: Bool, wanted: Bool = true) -> Action {
        self.enabled = enabled; self.alwaysOn = alwaysOn; self.keepAlive = keepAlive
        if !enabled { return off() }
        switch phase {
        case .off:
            if sessionActive {
                guard wanted else { return .none }
                phase = .inUse; creating = true; return .create
            }
            if alwaysOn && wanted { phase = .standby; creating = true; return .create }
            return .none
        case .standby:
            if onlyDisplay || (alwaysOn && wanted) { return .none }
            return off()
        case .lingering:
            if !wanted && !onlyDisplay { return off() }
            guard alwaysOn else { return .none }
            phase = .standby
            return creating ? .none : .standby
        case .inUse:
            return .none
        }
    }

    /// Remove it now (menu). A connected viewer keeps it.
    public mutating func removeRequested() -> Action {
        guard phase != .off, phase != .inUse else { return .none }
        return off()
    }

    /// Creation failed, or the system terminated the display: back to off (the next session or
    /// settings change tries again).
    public mutating func lost() { phase = .off; creating = false; resuming = 0; displaysChangedDuringCreate = false }

    /// Hiding the idle display failed (the transaction was refused): retry after this many seconds,
    /// `attempt` counting from 1; nil after the last (the next display change tries again).
    public static func standbyRetryDelay(attempt: Int) -> Double? {
        let delays: [Double] = [2, 5, 15]
        return attempt >= 1 && attempt <= delays.count ? delays[attempt - 1] : nil
    }
}

/// How the virtual display sits among the Mac's displays (host state; `VirtualDisplayTopology` is
/// the choice for streaming).
public enum VirtualDisplayLayout: Equatable, Sendable {
    /// Untouched (alone, or extended where macOS put it).
    case none
    /// `physical` mirrors the virtual display, which is at (0,0) (streaming, "mirror").
    case mirror(physical: UInt32)
    /// The virtual display was made main (streaming, "extend"); `previousMain` gets it back.
    case extendMain(previousMain: UInt32)
    /// The virtual display mirrors `physical`: hidden while idle (no extra desktop area).
    case hidden(behind: UInt32)

    /// The physical display the layout involves.
    public var physical: UInt32? {
        switch self {
        case let .mirror(p), let .hidden(p), let .extendMain(p): return p
        case .none: return nil
        }
    }

    /// The monitor that mirrors the virtual display.
    public var mirroring: UInt32? { if case let .mirror(p) = self { return p }; return nil }

    /// One step that brings the recorded layout back in line with the displays online now.
    public enum Fix: Equatable, Sendable {
        /// The layout's physical display went offline (lid closed, unplugged): forget it without a
        /// display-configuration transaction on the offline display. If it mirrored the virtual
        /// display, its mode is restored once it is back.
        case forget(UInt32)
        /// A monitor mirrors the virtual display outside the layout (it came back online still
        /// mirroring, for example the built-in panel when the lid opens): end that mirror, then
        /// restore its mode.
        case unmirror(UInt32)
        /// Streaming with "mirror" and no mirror in place while a monitor mirrors the virtual
        /// display: take it as the streaming mirror.
        case adopt(UInt32)
    }

    /// The fixes for `displays` (every online display except the virtual one and Glide's
    /// leftovers, with whom each mirrors). Run on screen-parameter changes.
    public static func reconcile(_ layout: VirtualDisplayLayout, virtual: UInt32, streaming: Bool, mode: VirtualDisplayMonitorMode,
                                 displays: [VirtualDisplayTopology.Display]) -> [Fix] {
        var fixes: [Fix] = []
        var layout = layout
        if let p = layout.physical, !displays.contains(where: { $0.id == p }) {
            fixes.append(.forget(p))
            layout = .none
        }
        for d in displays where d.mirrorOf == virtual && layout.mirroring != d.id {
            if streaming, mode == .mirror, layout == .none {
                fixes.append(.adopt(d.id))
                layout = .mirror(physical: d.id)
            } else {
                fixes.append(.unmirror(d.id))
            }
        }
        return fixes
    }
}

/// How the virtual display sits among the Mac's displays while it is streamed.
public enum VirtualDisplayTopology: Equatable, Sendable {
    /// No other display: it is the Mac's screen (and main) by itself.
    case alone
    /// `physical` (the main monitor) mirrors the virtual display, which is at (0,0): one desktop.
    case mirror(physical: UInt32)
    /// Beside the other displays; `main`: translated to (0,0) so it is the main display.
    case extend(main: Bool)

    /// One online display as CoreGraphics reports it.
    public struct Display: Equatable, Sendable {
        public var id: UInt32
        /// The display it mirrors (0 = none).
        public var mirrorOf: UInt32
        public init(id: UInt32, mirrorOf: UInt32 = 0) { self.id = id; self.mirrorOf = mirrorOf }
    }

    /// The arrangement for streaming `virtual`. `main` is the main display right now.
    public static func choose(mode: VirtualDisplayMonitorMode, makeMain: Bool, virtual: UInt32, main: UInt32, displays: [Display]) -> VirtualDisplayTopology {
        let others = displays.filter { $0.id != virtual }
        guard !others.isEmpty else { return .alone }
        guard mode == .mirror else { return .extend(main: makeMain) }
        // Already set up (a reconnect): keep the monitor that mirrors us.
        if let m = others.first(where: { $0.mirrorOf == virtual }) { return .mirror(physical: m.id) }
        // Mirror the main monitor, unless the user already mirrors displays (their setup wins).
        guard let target = others.first(where: { $0.id == main }) ?? others.first(where: { $0.mirrorOf == 0 }),
              target.mirrorOf == 0, !others.contains(where: { $0.mirrorOf == target.id }) else { return .extend(main: makeMain) }
        return .mirror(physical: target.id)
    }

    /// Whether a virtual display should be created at all with these physical displays online.
    public static func wantsVirtual(mode: VirtualDisplayMonitorMode, physicalDisplays: Int) -> Bool {
        mode != .stream || physicalDisplays == 0
    }
}

/// Display arrangement helpers (global display coordinates, points).
public enum VirtualDisplayArrangement {
    /// Origins that make `target` the main display (macOS: the display at (0,0)) by translating
    /// the whole arrangement, so relative positions are kept and nothing overlaps.
    public static func makingMain(_ target: UInt32, origins: [UInt32: (x: Double, y: Double)]) -> [UInt32: (x: Double, y: Double)]? {
        guard let t = origins[target] else { return nil }
        return origins.mapValues { (x: $0.x - t.x, y: $0.y - t.y) }
    }
}

extension DisplayModeInfo {
    /// Parses the machine-readable line of `glide-host --list-display-modes ID`
    /// ("current: 1280x720 px=2560x1440 hz=120"), which reports the mode from another process:
    /// CoreGraphics reports no mode for a virtual display to the process that created it.
    public static func parseListing(_ listing: String) -> DisplayModeInfo? {
        guard let line = listing.split(separator: "\n").first(where: { $0.hasPrefix("current: ") }) else { return nil }
        let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 5, nums[0] > 0, nums[1] > 0, nums[2] > 0, nums[3] > 0 else { return nil }
        return DisplayModeInfo(width: nums[0], height: nums[1], pixelWidth: nums[2], pixelHeight: nums[3], refreshRate: Double(nums[4]))
    }
}
