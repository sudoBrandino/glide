import Foundation

// The Mac viewer's connection manager (glide-viewer's Connections window), UI-free and unit-tested
// by glide-selftest. It follows the Windows viewer's Connections window (windows/src/connections.rs):
// the same validation, duplicate naming, removal and unpairing rules, row order and "last used"
// texts, so both connection lists behave alike. All state is `ViewerConfig` (viewer.json).

/// Longest name / group accepted (characters), as in the Windows viewer.
public let viewerConnectionMaxName = 64

/// What the Add / Edit form produces, and what `ViewerConfig.validate` checks. `address` may carry
/// a port (`HOST:PORT`); `port` is the separate Port field (blank = the platform's default).
public struct ConnectionDraft: Equatable, Sendable {
    public var name: String
    public var address: String
    public var port: String
    public var group: String
    public var favorite: Bool

    public init(name: String = "", address: String = "", port: String = "", group: String = "", favorite: Bool = false) {
        self.name = name; self.address = address; self.port = port; self.group = group; self.favorite = favorite
    }

    /// The form's contents for a saved connection: the address split into host and explicit port.
    public init(saved s: SavedConnection) {
        name = s.name
        group = s.group ?? ""
        favorite = s.favorite
        if let t = ViewerTarget.parse(s.address, defaultPort: 0) {
            address = t.host.contains(":") ? "[\(t.host)]" : t.host
            port = t.port == 0 ? "" : String(t.port)
        } else {
            address = s.address
            port = ""
        }
    }
}

/// A field the form should point at when validation fails.
public enum ConnectionField: Equatable, Sendable { case name, address, port, group }

public struct ConnectionDraftError: Error, Equatable, Sendable, CustomStringConvertible {
    public var field: ConnectionField
    public var message: String
    public init(_ field: ConnectionField, _ message: String) { self.field = field; self.message = message }
    public var description: String { message }
}

/// The checked result of a draft: what is stored.
public struct ValidConnection: Equatable, Sendable {
    public var name: String
    /// `HOST` or `HOST:PORT` (IPv6 in brackets), as stored in `SavedConnection.address`.
    public var address: String
    public var group: String?
    public var favorite: Bool
}

/// What `removeConnection` did, for the caller to report.
public struct RemovedConnection: Equatable, Sendable {
    public var name: String
    /// The host key pinned for it was forgotten (no other saved connection uses that address).
    public var unpaired: Bool
    public init(name: String, unpaired: Bool) { self.name = name; self.unpaired = unpaired }
}

/// One line of the Connections list.
public struct ConnectionRow: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The address as saved, plus the default port when it has none ("192.168.1.20:7421").
    public var address: String
    public var group: String
    /// "Paired with GAMING-PC" / "Paired" / "Not paired yet" / "Not supported by this viewer".
    public var status: String
    public var paired: Bool
    /// "Just now", "3 hours ago", "Never".
    public var lastUsed: String
    public var favorite: Bool
    /// The platform is one this viewer can connect to and the address parses.
    public var supported: Bool
}

extension SavedConnection {
    /// Platforms this viewer can open: a Windows host, or a Mac host (same protocol).
    public static let supportedPlatforms: Set<String> = ["windows", "mac"]

    public var isSupported: Bool { SavedConnection.supportedPlatforms.contains(platform.lowercased()) && target != nil }
}

extension ViewerConfig {
    /// Checks and cleans up a draft: trimmed, whitespace collapsed, a blank name filled from the
    /// address, the port folded into the address. `editing` is the id being edited (excluded from
    /// the duplicate-name check).
    public func validate(_ draft: ConnectionDraft, editing: String? = nil) -> Result<ValidConnection, ConnectionDraftError> {
        let raw = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(ConnectionDraftError(.address, "Enter the PC's address (a name or an IP address)")) }
        guard !raw.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" || $0 == "?" || $0 == "#" }) else {
            return .failure(ConnectionDraftError(.address, "Enter only a host name or an IP address, e.g. 192.168.1.20"))
        }
        // Parsed with default port 0: an address without an explicit port has port 0.
        guard let t = ViewerTarget.parse(raw, defaultPort: 0) else {
            return .failure(ConnectionDraftError(.address, "“\(raw)” is not HOST or HOST:PORT"))
        }
        var port = t.port
        let portText = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !portText.isEmpty {
            guard let p = UInt16(portText), p != 0 else { return .failure(ConnectionDraftError(.port, "The port must be a number from 1 to 65535")) }
            if port != 0 && port != p { return .failure(ConnectionDraftError(.port, "The address already names port \(port)")) }
            port = p
        }
        let address = port == 0 ? (t.host.contains(":") ? "[\(t.host)]" : t.host) : ViewerTarget(host: t.host, port: port).display

        var name = ViewerConfig.collapseWhitespace(draft.name)
        if name.isEmpty { name = address }
        if name.count > viewerConnectionMaxName {
            return .failure(ConnectionDraftError(.name, "Use a shorter name (at most \(viewerConnectionMaxName) characters)"))
        }
        let group = ViewerConfig.collapseWhitespace(draft.group)
        if group.count > viewerConnectionMaxName {
            return .failure(ConnectionDraftError(.group, "Use a shorter group name (at most \(viewerConnectionMaxName) characters)"))
        }
        if let clash = connections.first(where: { $0.id != editing && $0.name.lowercased() == name.lowercased() }) {
            return .failure(ConnectionDraftError(.name, "There is already a connection named “\(clash.name)”"))
        }
        return .success(ValidConnection(name: name, address: address, group: group.isEmpty ? nil : group, favorite: draft.favorite))
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Adds a validated draft (a Windows host). Returns the new connection.
    public mutating func addConnection(_ draft: ConnectionDraft) -> Result<SavedConnection, ConnectionDraftError> {
        validate(draft).map { v in
            let c = SavedConnection(name: v.name, platform: "windows", address: v.address, group: v.group, favorite: v.favorite)
            connections.append(c)
            return c
        }
    }

    /// Replaces a connection's settings (its platform, id and last use are kept). A changed address
    /// keeps the old address's pin where it is: the new address pairs on its first connect.
    public mutating func updateConnection(id: String, _ draft: ConnectionDraft) -> Result<Void, ConnectionDraftError> {
        guard let i = connections.firstIndex(where: { $0.id == id }) else {
            return .failure(ConnectionDraftError(.name, "That connection no longer exists"))
        }
        return validate(draft, editing: id).map { v in
            connections[i].name = v.name
            connections[i].address = v.address
            connections[i].group = v.group
            connections[i].favorite = v.favorite
        }
    }

    /// A copy named "NAME (copy)", then "NAME (copy 2)", …, never used. Returns the new id.
    public mutating func duplicateConnection(id: String) -> String? {
        guard let src = connections.first(where: { $0.id == id }) else { return nil }
        let names = Set(connections.map { $0.name.lowercased() })
        let taken = { (n: String) in names.contains(n.lowercased()) }
        var name = "\(src.name) (copy)"
        var k = 2
        while taken(name) {
            name = "\(src.name) (copy \(k))"
            k += 1
        }
        var copy = src
        copy.id = UUID().uuidString
        copy.name = name
        copy.lastConnected = nil
        connections.append(copy)
        return copy.id
    }

    /// Deletes a connection. Its pinned host key is forgotten unless another saved connection still
    /// uses the same address.
    public mutating func removeConnection(id: String) -> RemovedConnection? {
        guard let pos = connections.firstIndex(where: { $0.id == id }) else { return nil }
        let s = connections.remove(at: pos)
        var out = RemovedConnection(name: s.name, unpaired: false)
        if let key = s.target?.pinKey, !connections.contains(where: { $0.target?.pinKey == key }) {
            out.unpaired = pinnedHosts.removeValue(forKey: key) != nil
        }
        return out
    }

    /// Forgets the pinned host key of a saved connection (it pairs again on the next connect).
    @discardableResult
    public mutating func unpair(id: String) -> Bool {
        guard let t = connections.first(where: { $0.id == id })?.target else { return false }
        return forget(t)
    }

    /// The pin for a saved connection, if it is paired.
    public func pairing(for s: SavedConnection) -> PinnedHostEntry? {
        guard let t = s.target, let p = pinnedHosts[t.pinKey], p.keyData != nil else { return nil }
        return p
    }

    /// Distinct group names, sorted case-insensitively (for the group picker).
    public var connectionGroups: [String] {
        var seen = Set<String>()
        return connections.compactMap(\.group).filter { !$0.isEmpty }
            .sorted { $0.lowercased() < $1.lowercased() }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The rows to show: those matching `filter` (name, address or group; case-insensitive),
    /// grouped (ungrouped first, then groups A→Z), favorites first within a group, then by name.
    public func connectionRows(filter: String = "", now: Date = Date()) -> [ConnectionRow] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = connections.filter { s in
            f.isEmpty || s.name.lowercased().contains(f) || s.address.lowercased().contains(f) || (s.group ?? "").lowercased().contains(f)
        }
        let sorted = matching.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            let gx = x.group?.lowercased(), gy = y.group?.lowercased()
            if gx != gy {
                guard let gx else { return true }
                guard let gy else { return false }
                return gx < gy
            }
            if x.favorite != y.favorite { return x.favorite }
            if x.name.lowercased() != y.name.lowercased() { return x.name.lowercased() < y.name.lowercased() }
            return a.offset < b.offset
        }.map(\.element)
        return sorted.map { s in
            let supported = s.isSupported
            let pin = supported ? pairing(for: s) : nil
            let status: String
            if !supported {
                status = s.target == nil ? "Invalid address" : "Not supported by this viewer"
            } else if let pin {
                let n = pin.name.trimmingCharacters(in: .whitespaces)
                status = n.isEmpty ? "Paired" : "Paired with \(n)"
            } else {
                status = "Not paired yet"
            }
            return ConnectionRow(id: s.id, name: s.name, address: s.target?.display ?? s.address, group: s.group ?? "", status: status,
                                 paired: pin != nil, lastUsed: s.lastConnected.map { ViewerConfig.relativeTime($0, now: now) } ?? "Never",
                                 favorite: s.favorite, supported: supported)
        }
    }

    /// "Just now", "5 minutes ago", "Yesterday", "12 days ago", or the date for older ones (as the
    /// Windows viewer shows them). "Unknown" for a timestamp that doesn't parse.
    public static func relativeTime(_ iso: String, now: Date) -> String {
        guard let t = ISO8601DateFormatter().date(from: iso.trimmingCharacters(in: .whitespaces)) else { return "Unknown" }
        let d = max(0, Int(now.timeIntervalSince(t)))
        func plural(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago" }
        switch d {
        case 0 ..< 60: return "Just now"
        case 60 ..< 3600: return plural(d / 60, "minute")
        case 3600 ..< 86400: return plural(d / 3600, "hour")
        case 86400 ..< 172_800: return "Yesterday"
        case _ where d < 30 * 86400: return plural(d / 86400, "day")
        default: return String(iso.trimmingCharacters(in: .whitespaces).prefix(10))
        }
    }
}
