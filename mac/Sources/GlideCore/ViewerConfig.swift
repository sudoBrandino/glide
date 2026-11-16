import CryptoKit
import Foundation

// The Mac viewer's (glide-viewer, docs/WINDOWS_HOST.md) persistent state, UI-free and unit-tested
// by glide-selftest: connection targets and their pin keys, viewer.json, and the identity key file.

/// A host to dial: `HOST[:PORT]`, IPv6 in brackets when a port is given (`[fe80::1]:7421`).
public struct ViewerTarget: Equatable, Hashable, Sendable {
    /// Host name or address, without brackets.
    public var host: String
    public var port: UInt16

    /// The Windows host's default port (docs/WINDOWS_HOST.md "Ports").
    public static let defaultPort: UInt16 = 7421
    /// A Mac host's default port (PROTOCOL.md conventions).
    public static let macDefaultPort: UInt16 = 7420

    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    /// The default port for a saved connection's `platform`.
    public static func standardPort(platform: String?) -> UInt16 {
        platform?.lowercased() == "mac" ? macDefaultPort : defaultPort
    }

    /// Parses `HOST`, `HOST:PORT`, `[V6]`, `[V6]:PORT` or a bare IPv6 address (several colons,
    /// no port; same rule as the Windows viewer's `net::parse_addr`). nil for an empty host or a
    /// bad port.
    public static func parse(_ raw: String, defaultPort: UInt16 = ViewerTarget.defaultPort) -> ViewerTarget? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex) ..< close])
            guard !host.isEmpty else { return nil }
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return ViewerTarget(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let p = UInt16(String(rest.dropFirst())), p != 0 else { return nil }
            return ViewerTarget(host: host, port: p)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 0 { return ViewerTarget(host: s, port: defaultPort) }
        if colons > 1 { return ViewerTarget(host: s, port: defaultPort) }  // bare IPv6
        guard let i = s.firstIndex(of: ":") else { return nil }
        let host = String(s[..<i]), portText = String(s[s.index(after: i)...])
        guard !host.isEmpty, let p = UInt16(portText), p != 0 else { return nil }
        return ViewerTarget(host: host, port: p)
    }

    /// `host:port` (IPv6 in brackets), as typed.
    public var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Key of `pinnedHosts` in viewer.json: `display`, lowercase (PROTOCOL.md §2.3).
    public var pinKey: String { display.lowercased() }
}

/// One saved connection (docs/WINDOWS_HOST.md "Saved connections"; same fields as the Windows
/// viewer's connection list). Decoding is tolerant of missing fields, not of wrong types.
public struct SavedConnection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The host's OS: "windows" or "mac".
    public var platform: String
    /// `HOST[:PORT]` in one string.
    public var address: String
    public var group: String?
    public var favorite: Bool
    /// ISO 8601 UTC time of the last successful session.
    public var lastConnected: String?

    public init(id: String = UUID().uuidString, name: String, platform: String = "windows", address: String,
                group: String? = nil, favorite: Bool = false, lastConnected: String? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.address = address
        self.group = group; self.favorite = favorite; self.lastConnected = lastConnected
    }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, address, group, favorite, lastConnected
        /// Early drafts kept the port separately; folded into `address` when read.
        case port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "windows"
        var addr = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        // (Parsed with default port 0, an address without an explicit port has port 0.)
        if let port = try c.decodeIfPresent(UInt16.self, forKey: .port), port != 0,
           let t = ViewerTarget.parse(addr, defaultPort: 0), t.port == 0 {
            addr = ViewerTarget(host: t.host, port: port).display
        }
        address = addr
        // An entry written without an id gets one derived from its contents, so every read of the
        // file gives it the same id (a random one would change between loading the list and the
        // read-modify-write that removes or updates the entry).
        id = decodedID ?? SavedConnection.derivedID(name: name, platform: platform, address: addr)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        lastConnected = try c.decodeIfPresent(String.self, forKey: .lastConnected)
    }

    /// A stable UUID-shaped id from an entry's contents (for entries saved without one).
    public static func derivedID(name: String, platform: String, address: String) -> String {
        let d = Array(SHA256.hash(data: Data("glide-viewer connection\u{0}\(name)\u{0}\(platform)\u{0}\(address)".utf8)))
        let hex = d.prefix(16).map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.map { String($0) }.joined(separator: "-")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(platform, forKey: .platform)
        try c.encode(address, forKey: .address)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encode(favorite, forKey: .favorite)
        try c.encodeIfPresent(lastConnected, forKey: .lastConnected)
    }

    /// The target to dial, with the platform's default port.
    public var target: ViewerTarget? { ViewerTarget.parse(address, defaultPort: ViewerTarget.standardPort(platform: platform)) }
}

/// A pinned host key: viewer.json `pinnedHosts[target]`.
public struct PinnedHostEntry: Codable, Equatable, Sendable {
    /// X25519 static public key, 64 hex chars.
    public var key: String
    /// The host's name (ServerHello), for display.
    public var name: String
    /// When it was paired (ISO 8601 UTC).
    public var paired: String

    public init(key: String, name: String, paired: String) { self.key = key; self.name = name; self.paired = paired }

    enum CodingKeys: String, CodingKey { case key, name, paired }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        paired = try c.decodeIfPresent(String.self, forKey: .paired) ?? ""
    }

    public var keyData: Data? {
        guard key.count == 64, let d = Data(hex: key), d.count == 32 else { return nil }
        return d
    }
}

/// `~/Library/Application Support/Glide/viewer.json`.
public struct ViewerConfig: Codable, Equatable, Sendable {
    public var connections: [SavedConnection]
    /// Keyed by `ViewerTarget.pinKey`.
    public var pinnedHosts: [String: PinnedHostEntry]
    /// Command → Control, Control → Windows, Option → Alt (docs/WINDOWS_HOST.md "Keyboard mapping").
    public var remapModifiers: Bool

    public init(connections: [SavedConnection] = [], pinnedHosts: [String: PinnedHostEntry] = [:], remapModifiers: Bool = true) {
        self.connections = connections; self.pinnedHosts = pinnedHosts; self.remapModifiers = remapModifiers
    }

    enum CodingKeys: String, CodingKey { case connections, pinnedHosts, remapModifiers }

    /// Missing keys get defaults; a value of the wrong type throws, so `ConfigFile` refuses to
    /// write over a file it can't fully understand (it may hold pins).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connections = try c.decodeIfPresent([SavedConnection].self, forKey: .connections) ?? []
        pinnedHosts = try c.decodeIfPresent([String: PinnedHostEntry].self, forKey: .pinnedHosts) ?? [:]
        remapModifiers = try c.decodeIfPresent(Bool.self, forKey: .remapModifiers) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connections, forKey: .connections)
        try c.encode(pinnedHosts, forKey: .pinnedHosts)
        try c.encode(remapModifiers, forKey: .remapModifiers)
    }

    public static func timestamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// The valid key pinned for `t`, if any.
    public func pinnedKey(for t: ViewerTarget) -> Data? { pinnedHosts[t.pinKey]?.keyData }

    public mutating func pin(_ t: ViewerTarget, key: Data, name: String, at date: Date) {
        pinnedHosts[t.pinKey] = PinnedHostEntry(key: key.hex, name: name, paired: ViewerConfig.timestamp(date))
    }

    /// Updates the display name of the pin for `t` when it holds `key` (after ServerHello).
    public mutating func renamePin(_ t: ViewerTarget, key: Data, name: String) {
        guard var p = pinnedHosts[t.pinKey], p.keyData == key, p.name != name, !name.isEmpty else { return }
        p.name = name
        pinnedHosts[t.pinKey] = p
    }

    /// Removes the pin for `t`. Returns whether there was one.
    @discardableResult
    public mutating func forget(_ t: ViewerTarget) -> Bool { pinnedHosts.removeValue(forKey: t.pinKey) != nil }

    /// The saved connection with this name (case-insensitive).
    public func connection(named name: String) -> SavedConnection? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.first { $0.name.lowercased() == n }
    }

    /// Index of the saved connection with `id`, else the first whose address is `t`.
    public func connectionIndex(id: String?, target t: ViewerTarget) -> Int? {
        if let id, let i = connections.firstIndex(where: { $0.id == id }) { return i }
        return connections.firstIndex { $0.target?.pinKey == t.pinKey }
    }

    /// A command-line argument: a saved connection's name, else an address.
    public func resolve(_ arg: String) -> (target: ViewerTarget, connectionID: String?)? {
        if let c = connection(named: arg), let t = c.target { return (t, c.id) }
        guard let t = ViewerTarget.parse(arg) else { return nil }
        return (t, connectionIndex(id: nil, target: t).map { connections[$0].id })
    }

    /// Records a successful session on the matching saved connection (if any).
    public mutating func markConnected(id: String?, target t: ViewerTarget, at date: Date) {
        guard let i = connectionIndex(id: id, target: t) else { return }
        connections[i].lastConnected = ViewerConfig.timestamp(date)
    }

    @discardableResult
    public mutating func add(name: String, address: String, platform: String = "windows") -> SavedConnection {
        let c = SavedConnection(name: name, platform: platform, address: address)
        connections.append(c)
        return c
    }

    public mutating func remove(id: String) { connections.removeAll { $0.id == id } }
}

/// Where the viewer keeps its files. `GLIDE_VIEWER_DIR` overrides the folder (tests).
public enum ViewerPaths {
    public static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["GLIDE_VIEWER_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glide", isDirectory: true)
    }
    public static var config: URL { directory.appendingPathComponent("viewer.json") }
    public static var key: URL { directory.appendingPathComponent("viewer-key") }

    /// Creates the folder (mode 0700) if needed.
    public static func ensureDirectory(_ dir: URL = directory) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// The viewer's static X25519 identity: 64 hex chars in `viewer-key` (mode 0600). Created when
/// there is no file; a file that can't be read or isn't a valid key is an error, never replaced
/// (a new key would look like an impostor to every paired host).
public enum ViewerIdentity {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case corrupt(path: String)
        case unwritable(path: String, reason: String)
        public var description: String {
            switch self {
            case let .unreadable(p, r): return "\(p) can't be read (\(r)); fix or move it (a new key means pairing every host again)"
            case let .corrupt(p): return "\(p) is not a valid key (expected 64 hex characters); fix or move it (a new key means pairing every host again)"
            case let .unwritable(p, r): return "\(p) can't be written (\(r))"
            }
        }
    }

    /// Parses the key file's text.
    public static func parse(_ text: String) -> Curve25519.KeyAgreement.PrivateKey? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 64, let d = Data(hex: t), d.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d)
    }

    public static func loadOrCreate(at url: URL = ViewerPaths.key) throws -> Curve25519.KeyAgreement.PrivateKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let text: String
            do { text = try String(contentsOf: url, encoding: .utf8) } catch {
                // Not UTF-8 at all: as corrupt as a wrong length.
                if let d = try? Data(contentsOf: url), String(data: d, encoding: .utf8) == nil { throw Failure.corrupt(path: url.path) }
                throw Failure.unreadable(path: url.path, reason: (error as NSError).localizedDescription)
            }
            guard let k = parse(text) else { throw Failure.corrupt(path: url.path) }
            return k
        }
        do { try ViewerPaths.ensureDirectory(url.deletingLastPathComponent()) } catch {
            throw Failure.unwritable(path: url.path, reason: (error as NSError).localizedDescription)
        }
        let k = Curve25519.KeyAgreement.PrivateKey()
        let data = Data((k.rawRepresentation.hex + "\n").utf8)
        // O_EXCL: never overwrite a key that appeared meanwhile (a second instance).
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { return try loadOrCreate(at: url) }
            throw Failure.unwritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        let written = data.withUnsafeBytes { p -> Int in write(fd, p.baseAddress, p.count) }
        close(fd)
        guard written == data.count else {
            unlink(url.path)
            throw Failure.unwritable(path: url.path, reason: "short write")
        }
        return k
    }
}
