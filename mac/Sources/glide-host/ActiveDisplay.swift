import AppKit
import CoreGraphics
import GlideCore

/// The display Glide serves, and the Mac's display list (PROTOCOL.md §3.5).
///
/// Resolution order: the active session's selection (by identity, so a re-plugged monitor with a
/// new ID is followed), else the `--display` pin while that display is online, otherwise whatever
/// is the main display right now. Works for any `CGDirectDisplayID`, virtual displays included.
///
/// Never cache a display ID across a session. IDs go stale when the lid closes or a monitor is
/// swapped, and CoreGraphics keeps answering for an offline ID (CGDisplayBounds returns its last
/// size), so a stale ID silently maps input onto the wrong rectangle instead of failing.
enum ActiveDisplay {
    /// `--display N`. Set once at startup, before any session starts.
    static var pinned: CGDirectDisplayID?

    private static let lock = NSLock()
    private static var _selection: (owner: Int, identity: DisplayIdentity)?
    /// Localized names by display ID, refreshed on the main thread (NSScreen is main-thread only).
    private static var _names: [CGDirectDisplayID: String] = [:]

    /// The active session's choice (SelectDisplay / menu bar), nil = follow the default.
    static var selection: DisplayIdentity? { lock.withLock { _selection?.identity } }

    static func select(_ identity: DisplayIdentity?, owner: Int) {
        lock.withLock { _selection = identity.map { (owner, $0) } }
    }

    /// Session `owner` ended: drop its selection (a newer session's choice stays).
    static func clearSelection(owner: Int) {
        lock.withLock { if _selection?.owner == owner { _selection = nil } }
    }

    static func current() -> CGDirectDisplayID {
        let sel = selection
        // Fast path (input injection calls this): the selected display is still there.
        if let s = sel, isOnline(s.id), sameHardware(s.id, s) { return s.id }
        if sel == nil, pinned == nil { return CGMainDisplayID() }
        return DisplaySelection.resolve(selection: sel, pinned: pinned, main: CGMainDisplayID(), displays: displays())
    }

    /// What the host streams without a selection.
    static func defaultDisplay() -> CGDirectDisplayID {
        guard pinned != nil else { return CGMainDisplayID() }
        return DisplaySelection.defaultDisplay(pinned: pinned, main: CGMainDisplayID(), displays: displays())
    }

    static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0
    }

    private static func sameHardware(_ id: CGDirectDisplayID, _ s: DisplayIdentity) -> Bool {
        CGDisplayVendorNumber(id) == s.vendor && CGDisplayModelNumber(id) == s.model && CGDisplaySerialNumber(id) == s.serial
    }

    /// The online (awake), non-mirrored displays in list order (§3.5). CoreGraphics only, so it is
    /// safe on any thread; names come from the cache `refreshNames()` fills on the main thread.
    static func displays() -> [DisplayDescriptor] {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
        let names = lock.withLock { _names }
        let main = CGMainDisplayID()
        let def = pinned.flatMap { p in ids.contains(p) && isOnline(p) ? p : nil } ?? main
        var out: [DisplayDescriptor] = []
        for id in ids.prefix(Int(n)) where isOnline(id) {
            // A hardware mirror set is one picture: list only its master.
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let w = mode?.width ?? Int(b.width), h = mode?.height ?? Int(b.height)
            let pw = mode?.pixelWidth ?? w, ph = mode?.pixelHeight ?? h
            var flags: UInt8 = 0
            if id == main { flags |= DisplayDescriptor.flagMain }
            if CGDisplayIsBuiltin(id) != 0 { flags |= DisplayDescriptor.flagBuiltIn }
            if pw > w { flags |= DisplayDescriptor.flagHiDPI }
            if id == def { flags |= DisplayDescriptor.flagDefault }
            let hz = (mode?.refreshRate ?? 0) * 100
            out.append(DisplayDescriptor(
                id: id, flags: flags, x: Int32(clamping: Int(b.minX.rounded())), y: Int32(clamping: Int(b.minY.rounded())),
                width: UInt16(clamping: w), height: UInt16(clamping: h), pixelWidth: UInt16(clamping: pw), pixelHeight: UInt16(clamping: ph),
                refresh: hz.isFinite ? UInt16(clamping: Int(hz.rounded())) : 0,
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")))
        }
        return DisplaySelection.ordered(out)
    }

    /// Refresh the name cache from NSScreen. Call on the main thread (startup, screen changes).
    static func refreshNames() {
        dispatchPrecondition(condition: .onQueue(.main))
        var names: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = s.localizedName
            }
        }
        lock.withLock { _names = names }
    }

    /// The listed display `id`, if online.
    static func descriptor(_ id: CGDirectDisplayID) -> DisplayDescriptor? { displays().first { $0.id == id } }
}
