import Foundation

// Pure logic for the optional virtual display (docs/VIRTUAL_DISPLAY.md). The CoreGraphics side
// lives in glide-host/VirtualDisplay.swift; everything here is unit-tested in glide-selftest.

/// host.json `"virtualDisplay"`. Every field is optional; out-of-range numbers are clamped and an
/// unknown `lifetime` means the default, so a typo in a value never disables the rest of host.json
/// (a wrong JSON type still does, as for every other section).
public struct VirtualDisplayConfig: Codable, Equatable, Sendable {
    /// Master switch (default false).
    public var enabled: Bool?
    /// "session" (default): exists while a viewer is connected, plus `keepAliveSeconds`.
    /// "always": created at launch and kept while the host runs.
    public var lifetime: String?
    /// Seconds to keep the display after the viewer disconnects, so a reconnect does not reshuffle
    /// windows (default 30, 0 = remove at once, capped at 24 h).
    public var keepAliveSeconds: Double?
    /// Make the virtual display the main display (menu bar, new windows) while it exists (default false).
    public var makeMain: Bool?
    /// Refresh rate of the virtual panel in Hz (default 60, 24...240). Glide's own capture rate is
    /// still capped by --fps / GLIDE_FPS.
    public var refreshRate: Double?
    /// Fixed panel size in pixels, used instead of the viewer's ViewSize (both must be set).
    /// Also the size an always-on display starts with before any viewer has connected.
    public var width: Int?
    public var height: Int?

    public init(enabled: Bool? = nil, lifetime: String? = nil, keepAliveSeconds: Double? = nil, makeMain: Bool? = nil,
                refreshRate: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.enabled = enabled; self.lifetime = lifetime; self.keepAliveSeconds = keepAliveSeconds
        self.makeMain = makeMain; self.refreshRate = refreshRate; self.width = width; self.height = height
    }

    public static let defaultKeepAlive: Double = 30
    public static let defaultSize = (w: 1920, h: 1080)

    public var isEnabled: Bool { enabled ?? false }
    public var alwaysOn: Bool { lifetime?.lowercased() == "always" }
    public var keepAlive: Double { min(max(keepAliveSeconds ?? Self.defaultKeepAlive, 0), 86_400) }
    public var wantsMain: Bool { makeMain ?? false }
    public var hz: Double { min(max(refreshRate ?? 60, 24), 240) }
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

    /// The mode macOS should end up in: looks-like size in points, backing size in pixels.
    public var expected: DisplayModeInfo {
        let s = hiDPI ? 2 : 1
        return DisplayModeInfo(width: modeWidth, height: modeHeight, pixelWidth: modeWidth * s, pixelHeight: modeHeight * s, refreshRate: refreshRate)
    }

    public var description: String { "\(style.rawValue) \(expected) @ \(Int(refreshRate.rounded())) Hz" }

    /// Largest backing size the planner produces (wider smooth plans fall back to retina).
    public static let maxBackingWidth = 7680
    public static let maxBackingHeight = 4320

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

    /// maxPixelsWide/High for a new display serving this viewer: big enough for every style
    /// (crisp, retina, smooth), so a preference change re-applies settings instead of re-creating.
    public static func maxPixels(viewerW: Int, viewerH: Int, highDPIChoice: HighDPIViewerChoice, refreshRate: Double) -> (w: Int, h: Int) {
        var w = 0, h = 0
        for p in [DisplayModePreference.crisp, .retina, .smooth] {
            guard let e = make(viewerW: viewerW, viewerH: viewerH, preference: p, highDPIChoice: highDPIChoice, refreshRate: refreshRate)?.expected else { continue }
            w = max(w, e.pixelWidth); h = max(h, e.pixelHeight)
        }
        return (w, h)
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
}

/// When the virtual display exists. Pure state machine; the host feeds it events and performs the
/// returned action. Times are seconds on any monotonic clock.
public struct VirtualDisplayLifecycle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No display.
        case off
        /// A viewer is connected and using it.
        case inUse
        /// The viewer left; removed at `until` unless one reconnects.
        case lingering(until: Double)
        /// Always-on, no viewer.
        case standby
    }

    public enum Action: Equatable, Sendable {
        case none
        case create
        case destroy
        /// Call `timerFired(now:)` at this time.
        case scheduleTimer(at: Double)
    }

    public private(set) var phase: Phase = .off
    public private(set) var sessionActive = false
    public private(set) var enabled = false
    public private(set) var alwaysOn = false
    public private(set) var keepAlive: Double = VirtualDisplayConfig.defaultKeepAlive

    public init(enabled: Bool = false, alwaysOn: Bool = false, keepAlive: Double = VirtualDisplayConfig.defaultKeepAlive) {
        self.enabled = enabled; self.alwaysOn = alwaysOn; self.keepAlive = keepAlive
    }

    public var exists: Bool { phase != .off }

    /// The host started.
    public mutating func launched() -> Action {
        guard enabled, alwaysOn, phase == .off else { return .none }
        phase = .standby
        return .create
    }

    public mutating func sessionBegan() -> Action {
        sessionActive = true
        guard enabled else { return .none }
        let wasOff = phase == .off
        phase = .inUse
        return wasOff ? .create : .none  // lingering/standby: reuse it (no window reshuffle)
    }

    public mutating func sessionEnded(now: Double) -> Action {
        sessionActive = false
        guard phase == .inUse else { return .none }
        if alwaysOn { phase = .standby; return .none }
        if keepAlive > 0 {
            phase = .lingering(until: now + keepAlive)
            return .scheduleTimer(at: now + keepAlive)
        }
        phase = .off
        return .destroy
    }

    /// A timer scheduled earlier fired. Stale timers (a viewer came back, or a newer linger
    /// started) are ignored.
    public mutating func timerFired(now: Double) -> Action {
        guard case let .lingering(until) = phase, now >= until - 0.05 else { return .none }
        phase = .off
        return .destroy
    }

    /// Settings changed (menu or host.json).
    public mutating func configure(enabled: Bool, alwaysOn: Bool, keepAlive: Double, now: Double) -> Action {
        self.enabled = enabled; self.alwaysOn = alwaysOn; self.keepAlive = keepAlive
        if !enabled {
            guard phase != .off else { return .none }
            phase = .off
            return .destroy
        }
        switch phase {
        case .off:
            if sessionActive { phase = .inUse; return .create }
            if alwaysOn { phase = .standby; return .create }
            return .none
        case .standby where !alwaysOn:
            phase = .off
            return .destroy
        case .lingering where alwaysOn:
            phase = .standby
            return .none
        default:
            return .none
        }
    }

    /// Remove it now (menu). A connected viewer keeps it.
    public mutating func removeRequested() -> Action {
        guard phase != .off, phase != .inUse else { return .none }
        phase = .off
        return .destroy
    }

    /// Creation failed, or the system terminated the display: back to off (the next session or
    /// settings change tries again).
    public mutating func lost() { phase = .off }
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
