import Foundation

/// The stable identity of a Mac display (PROTOCOL.md §3.5). `id` is the volatile
/// `CGDirectDisplayID` it had when remembered; `vendor`/`model`/`serial` come from the EDID
/// (0 = unknown) and `name` is the localized name.
public struct DisplayIdentity: Equatable, Sendable, Codable {
    public var id: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String

    public init(id: UInt32, vendor: UInt32, model: UInt32, serial: UInt32, name: String) {
        self.id = id; self.vendor = vendor; self.model = model; self.serial = serial; self.name = name
    }

    func sameHardware(_ d: DisplayDescriptor) -> Bool { d.vendor == vendor && d.model == model && d.serial == serial }

    /// The display in `list` this identity refers to, by the normative §3.5 rule:
    /// same id and hardware; else (serial known) the same vendor/model/serial; else (no serial) the
    /// same vendor/model with no serial — by name too when vendor and model are unknown —
    /// preferring an equal name. "First" is list order.
    public func match(in list: [DisplayDescriptor]) -> UInt32? {
        if let d = list.first(where: { $0.id == id && sameHardware($0) }) { return d.id }
        if serial != 0 { return list.first(where: sameHardware)?.id }
        var cands = list.filter(sameHardware)
        if vendor == 0 && model == 0 { cands = cands.filter { $0.name == name } }
        return (cands.first(where: { $0.name == name }) ?? cands.first)?.id
    }
}

/// One entry of DisplayList (0x06, §3.5).
public struct DisplayDescriptor: Equatable, Sendable {
    public static let flagMain: UInt8 = 1 << 0
    public static let flagBuiltIn: UInt8 = 1 << 1
    public static let flagHiDPI: UInt8 = 1 << 2
    /// What `SelectDisplay(0)` streams.
    public static let flagDefault: UInt8 = 1 << 3
    /// Hosts list at most this many displays.
    public static let listMax = 32

    public var id: UInt32
    public var flags: UInt8
    /// Top-left corner in global points (main display at 0,0; y grows downwards).
    public var x: Int32, y: Int32
    /// Current mode in points and backing pixels.
    public var width: UInt16, height: UInt16, pixelWidth: UInt16, pixelHeight: UInt16
    /// Refresh rate in 1/100 Hz, 0 = unknown.
    public var refresh: UInt16
    public var vendor: UInt32, model: UInt32, serial: UInt32
    public var name: String

    public init(id: UInt32, flags: UInt8 = 0, x: Int32 = 0, y: Int32 = 0, width: UInt16, height: UInt16, pixelWidth: UInt16, pixelHeight: UInt16,
                refresh: UInt16 = 0, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0, name: String) {
        self.id = id; self.flags = flags; self.x = x; self.y = y; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refresh = refresh
        self.vendor = vendor; self.model = model; self.serial = serial; self.name = name
    }

    public var identity: DisplayIdentity { DisplayIdentity(id: id, vendor: vendor, model: model, serial: serial, name: name) }
    public var isMain: Bool { flags & Self.flagMain != 0 }
    public var isBuiltIn: Bool { flags & Self.flagBuiltIn != 0 }

    /// "DELL U2723QE — 1920×1080 HiDPI @ 60 Hz" (menu bar, logs).
    public var summary: String {
        var s = "\(name) — \(width)×\(height)"
        if flags & Self.flagHiDPI != 0 { s += " HiDPI" }
        if refresh > 0 { s += String(format: " @ %g Hz", Double(refresh) / 100) }
        return s
    }

    func write(_ w: inout ByteWriter) {
        w.u32(id); w.u8(flags); w.u32(UInt32(bitPattern: x)); w.u32(UInt32(bitPattern: y))
        w.u16(width); w.u16(height); w.u16(pixelWidth); w.u16(pixelHeight); w.u16(refresh)
        w.u32(vendor); w.u32(model); w.u32(serial); w.str(name)
    }

    static func read(_ r: inout ByteReader) throws -> DisplayDescriptor {
        let id = try r.u32(), flags = try r.u8()
        let x = Int32(bitPattern: try r.u32()), y = Int32(bitPattern: try r.u32())
        let w = try r.u16(), h = try r.u16(), pw = try r.u16(), ph = try r.u16(), hz = try r.u16()
        let v = try r.u32(), m = try r.u32(), s = try r.u32()
        return DisplayDescriptor(id: id, flags: flags, x: x, y: y, width: w, height: h, pixelWidth: pw, pixelHeight: ph,
                                 refresh: hz, vendor: v, model: m, serial: s, name: try r.str())
    }
}

/// DisplayChanged (0x07) `reason` (§3.5).
public enum DisplayChangeReason: UInt8, Sendable, CaseIterable {
    /// The viewer's SelectDisplay was applied.
    case selected = 0
    /// The requested display isn't available; nothing changed.
    case unavailable = 1
    /// The selected display went away; streaming the default.
    case fallback = 2
    /// The selected display came back.
    case restored = 3
    /// Picked on the Mac (menu bar).
    case host = 4
    /// No selection, and the default display changed (new main display, lid closed).
    case defaultChanged = 5
}

/// Which display a session streams (§3.5): pure logic, unit-tested in glide-selftest.
public enum DisplaySelection {
    /// The display to stream: the selection while a listed display matches its identity, else the
    /// pinned display (`--display`) while listed, else the main display.
    public static func resolve(selection: DisplayIdentity?, pinned: UInt32?, main: UInt32, displays: [DisplayDescriptor]) -> UInt32 {
        if let s = selection, let id = s.match(in: displays) { return id }
        return defaultDisplay(pinned: pinned, main: main, displays: displays)
    }

    /// What `SelectDisplay(0)` streams.
    public static func defaultDisplay(pinned: UInt32?, main: UInt32, displays: [DisplayDescriptor]) -> UInt32 {
        if let p = pinned, displays.contains(where: { $0.id == p }) { return p }
        return main
    }

    /// List order: left to right (x, then y, then id), at most `DisplayDescriptor.listMax`.
    public static func ordered(_ ds: [DisplayDescriptor]) -> [DisplayDescriptor] {
        Array(ds.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }.prefix(DisplayDescriptor.listMax))
    }

    /// Why the streamed display changed to `now` when nobody asked for it (a capture restart after
    /// hot-plug): back on the selection, away from it, or the default moved.
    public static func unrequestedReason(selection: DisplayIdentity?, now: UInt32, displays: [DisplayDescriptor]) -> DisplayChangeReason {
        guard let s = selection else { return .defaultChanged }
        return s.match(in: displays) == now ? .restored : .fallback
    }
}
