import Foundation

// Restoring a display's own mode after Glide (or a mirror of Glide's virtual display) changed it.
// Pure logic, unit-tested in glide-selftest; the CoreGraphics side is
// glide-host/DisplayModeController.swift.

/// Display settings persisted in host.json under "display". Stored as strings and parsed leniently:
/// a typo must never make host.json undecodable (HostConfig.load would then fall back to defaults).
public struct DisplaySettings: Codable, Equatable, Sendable {
    /// automatic | crisp | smooth | retina | manual (default automatic)
    public var mode: String?
    /// What automatic picks for 4K-class viewers: retina (looks like 1920x1080) | smooth (looks like 2560x1440)
    public var highDPIViewer: String?
    /// Restore the pre-session display mode when the viewer disconnects (default true).
    public var restoreOnDisconnect: Bool?
    /// The mode to restore (set when Glide first switches the mode, or before a monitor mirrors the
    /// virtual display; cleared once restored).
    public var restore: DisplayModeInfo?
    /// The display ID `restore` belonged to when it was saved. Display IDs are reused after a
    /// reboot or a replug, so `restoreIdentity` decides; this is only read from files written
    /// before it existed (nil in even older files: the display being served).
    public var restoreDisplay: UInt32?
    /// The display `restore` belongs to, by §3.5 identity (vendor/model/serial).
    public var restoreIdentity: DisplayIdentity?
    /// `restore` was saved before the monitor mirrored the virtual display: it is the monitor's own
    /// mode, restored regardless of "restore on disconnect" and never dropped as a manual change.
    public var restoreFromMirror: Bool?

    public init(mode: String? = nil, highDPIViewer: String? = nil, restoreOnDisconnect: Bool? = nil,
                restore: DisplayModeInfo? = nil, restoreDisplay: UInt32? = nil, restoreIdentity: DisplayIdentity? = nil,
                restoreFromMirror: Bool? = nil) {
        self.mode = mode; self.highDPIViewer = highDPIViewer; self.restoreOnDisconnect = restoreOnDisconnect
        self.restore = restore; self.restoreDisplay = restoreDisplay; self.restoreIdentity = restoreIdentity
        self.restoreFromMirror = restoreFromMirror
    }

    public var preference: DisplayModePreference { mode.flatMap { DisplayModePreference(rawValue: $0.lowercased()) } ?? .automatic }
    public var highDPIChoice: HighDPIViewerChoice { highDPIViewer.flatMap { HighDPIViewerChoice(rawValue: $0.lowercased()) } ?? .retina }
    public var restoreEnabled: Bool { restoreOnDisconnect ?? true }
}

public enum ModeRestore {
    /// How long macOS takes to give a monitor a mode of its own after it stops mirroring. A restore
    /// before that is undone by macOS (it applies the monitor's persisted mode).
    public static let afterMirrorSettle: TimeInterval = 1.5
    /// Refresh rates within this are the same rate (CoreGraphics reports 59.94 / 60, 164.99 / 165).
    public static let refreshTolerance = 0.5

    /// Where a saved restore applies now.
    public enum Target: Equatable, Sendable {
        /// This display (online now).
        case display(UInt32)
        /// The display it was saved for isn't connected: keep the restore until it is.
        case notConnected
        /// Written before multi-display support: the display being served.
        case served
    }

    /// The display a saved restore belongs to among `online` (every online display, mirrored
    /// ones included). By identity: the same ID with the same hardware, else (serial known) the
    /// same vendor/model/serial, else (no serial) the one display with that vendor/model; never a
    /// different monitor that happens to get the old ID. Files without an identity use the bare ID
    /// as before.
    public static func resolve(identity: DisplayIdentity?, legacyID: UInt32?, online: [DisplayIdentity]) -> Target {
        guard let s = identity else {
            guard let id = legacyID else { return .served }
            return online.contains { $0.id == id } ? .display(id) : .notConnected
        }
        func same(_ d: DisplayIdentity) -> Bool { d.vendor == s.vendor && d.model == s.model && d.serial == s.serial }
        if let d = online.first(where: { $0.id == s.id && same($0) }) { return .display(d.id) }
        let cands = online.filter(same)
        if s.serial != 0, let d = cands.first { return .display(d.id) }
        // No serial: only an unambiguous vendor/model match (two identical monitors can't be told apart).
        if s.serial == 0, cands.count == 1, s.vendor != 0 || s.model != 0 { return .display(cands[0].id) }
        return .notConnected
    }

    /// What `rememberBeforeMirror` does with a pending restore.
    public enum BeforeMirror: Equatable, Sendable {
        /// Save the monitor's current mode.
        case remember
        /// A restore for this monitor is already pending: it holds the monitor's real mode (the
        /// current one may already be Glide's), so it is never overwritten.
        case keepPending
        /// A restore for another connected display is pending (one slot): leave it.
        case otherPending
    }

    /// `pending`: whether a restore is saved, and where it applies (`resolve`).
    public static func beforeMirror(pending: Target?, display: UInt32, served: UInt32) -> BeforeMirror {
        switch pending {
        case nil, .notConnected?: return .remember  // nothing saved, or saved for a display that's gone
        case let .display(id)?: return id == display ? .keepPending : .otherPending
        case .served?: return served == display ? .keepPending : .otherPending
        }
    }

    /// What restoring `saved` on a display currently in `current` with `available` modes does.
    public enum Choice: Equatable, Sendable {
        case alreadyThere
        case switchTo(DisplayModeInfo)
        case unavailable
    }

    /// Size (points and pixels) plus refresh rate, falling back to the size alone (the closest
    /// rate) when the saved rate no longer exists. A saved rate of 0 (some panels report none)
    /// matches on size.
    public static func choose(saved: DisplayModeInfo, current: DisplayModeInfo?, available: [DisplayModeInfo]) -> Choice {
        let sized = available.filter { $0.sameSize(saved) }
        let exact = sized.first { sameRate($0.refreshRate, saved.refreshRate) }
        if let c = current, c.sameSize(saved), sameRate(c.refreshRate, saved.refreshRate) || exact == nil { return .alreadyThere }
        if let m = exact { return .switchTo(m) }
        guard let m = sized.min(by: { abs($0.refreshRate - saved.refreshRate) < abs($1.refreshRate - saved.refreshRate) }) else { return .unavailable }
        return .switchTo(m)
    }

    public static func sameRate(_ a: Double, _ b: Double) -> Bool {
        a <= 0 || b <= 0 || abs(a - b) <= refreshTolerance
    }

    /// What a mode change Glide didn't make (DisplayChangeTracker `.manual`) on the served display does.
    public enum ManualChange: Equatable, Sendable {
        /// The display just stopped mirroring the virtual display: macOS is giving it a mode of its
        /// own. Not the user; accept the new mode and change nothing.
        case settling
        /// No viewer and nothing saved: nothing to do.
        case ignore
        /// A viewer is connected: stop auto-switching for this session; drop the saved restore
        /// unless it came from a mirror.
        case pauseSession(dropRestore: Bool)
        /// No viewer: the user picked a mode; the saved one (from Glide's own switch) is dropped.
        case dropRestore
        /// No viewer: keep the saved mode (it is the monitor's own, saved before it mirrored).
        case keepRestore
    }

    public static func manualChange(settling: Bool, viewerConnected: Bool, restorePending: Bool, restoreFromMirror: Bool) -> ManualChange {
        if settling { return .settling }
        if viewerConnected { return .pauseSession(dropRestore: restorePending && !restoreFromMirror) }
        guard restorePending else { return .ignore }
        return restoreFromMirror ? .keepRestore : .dropRestore
    }

    /// What a viewer disconnecting does with a saved restore: a mirror's saved mode is the monitor's
    /// own and always comes back (restoreAfterMirror; the scheduled restore waits for the mirror).
    public static func onSessionEnd(restoreEnabled: Bool, userOverride: Bool, restoreFromMirror: Bool) -> Bool {
        restoreFromMirror || (restoreEnabled && !userOverride)
    }

    /// How long the exit restore waits for a monitor whose mirror ended at `unmirroredAt`, so that
    /// macOS's own mode change after the mirror doesn't undo it. Never more than `afterMirrorSettle`.
    public static func exitWait(unmirroredAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let at = unmirroredAt else { return 0 }
        return min(afterMirrorSettle, max(0, at + afterMirrorSettle - now))
    }

    /// A monitor that mirrors a display with Glide's virtual-display identity (ours, or one whose
    /// removal macOS deferred while the displays slept) has its mode set by the mirror: a restore
    /// must wait until that mirror ends. `mirrorOf` is CGDisplayMirrorsDisplay (0 = none).
    public static func heldByMirror(recordedMirror: Bool, mirrorOf: UInt32, mirrorIsGlide: Bool) -> Bool {
        recordedMirror || (mirrorOf != 0 && mirrorIsGlide)
    }
}

/// Monitors whose mirror of the virtual display just ended. macOS gives such a monitor a mode of its
/// own about `afterMirrorSettle` later; that change is not the user's, and a restore before it is
/// undone. From `mirrorEnded` until the mirror-ended restore ran (plus `grace`), mode changes on the
/// display are not manual and other restores wait for that one.
public struct MirrorSettle: Equatable, Sendable {
    /// After the mirror-ended restore ran: macOS may still deliver the change it made.
    public static let grace: TimeInterval = 1
    /// Never waits longer than this for the mirror-ended restore (it is always scheduled, but a
    /// stuck run loop must not silence manual-change detection for good).
    public static let maxWait: TimeInterval = 10

    private struct Entry: Equatable, Sendable {
        var endedAt: TimeInterval
        /// When the mirror-ended restore ran (nil: still due).
        var restoredAt: TimeInterval?
    }
    private var entries: [UInt32: Entry] = [:]
    /// The most recent mirror end (for the exit restore's wait).
    public private(set) var lastDisplay: UInt32?
    public private(set) var lastEndedAt: TimeInterval?

    public init() {}

    public mutating func mirrorEnded(_ display: UInt32, at now: TimeInterval) {
        entries[display] = Entry(endedAt: now, restoredAt: nil)
        lastDisplay = display
        lastEndedAt = now
    }

    /// The mirror-ended restore for `display` ran (whatever it did).
    public mutating func restoreRan(_ display: UInt32, at now: TimeInterval) {
        guard entries[display] != nil else { return }
        entries[display]?.restoredAt = now
    }

    /// The mirror-ended restore is still due: other restores of `display` wait for it.
    public func awaitingRestore(_ display: UInt32, now: TimeInterval) -> Bool {
        guard let e = entries[display], e.restoredAt == nil else { return false }
        return now < e.endedAt + Self.maxWait
    }

    /// Mode changes on `display` now are macOS settling it after the mirror, not the user.
    public func isSettling(_ display: UInt32, now: TimeInterval) -> Bool {
        guard let e = entries[display] else { return false }
        if let r = e.restoredAt { return now < r + Self.grace }
        return now < e.endedAt + Self.maxWait
    }

    /// When `display` last stopped mirroring, if it did.
    public func endedAt(_ display: UInt32) -> TimeInterval? { entries[display]?.endedAt }
}
