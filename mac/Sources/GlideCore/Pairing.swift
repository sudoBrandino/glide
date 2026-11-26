import Foundation

/// Security v2 host-side trust logic (docs/PROTOCOL.md §2.3–2.5), UI-free and unit-tested by
/// glide-selftest: the paired-viewer record, AuthResult codes, the pairing window/slot, the
/// two-party confirmation, and the per-address rate limiter.

/// AuthResult codes (message 0x05).
public enum AuthCode: UInt8, CustomStringConvertible, Sendable {
    case ok = 0
    case unknownViewer = 1
    case pairingClosed = 2
    case declined = 3
    case timeout = 4
    case busy = 5

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .unknownViewer: return "unknown viewer"
        case .pairingClosed: return "pairing not open"
        case .declined: return "pairing declined"
        case .timeout: return "pairing timed out"
        case .busy: return "busy (another pairing in progress)"
        }
    }
}

/// One viewer allowed to connect: host.json `"pairedViewers": [...]`.
public struct PairedViewer: Codable, Equatable {
    public var name: String
    /// X25519 static public key, 64 hex chars.
    public var key: String
    /// When it was paired (ISO 8601 UTC).
    public var paired: String

    public init(name: String, key: Data, paired: Date) {
        self.name = name
        self.key = key.hex
        self.paired = ISO8601DateFormatter().string(from: paired)
    }

    public var keyData: Data? {
        guard key.count == 64, let d = Data(hex: key), d.count == 32 else { return nil }
        return d
    }

    public var fingerprint: String { keyData.map(GlideHandshake.fingerprint) ?? "invalid key" }

    /// Display name: the CloudText rules (controls, bidi and format characters, separators, tag
    /// characters and variation selectors removed, whitespace collapsed), at most 40 characters.
    public static func displayName(_ raw: String) -> String {
        CloudText.name(raw, fallback: "unnamed viewer", max: 40)
    }
}

/// The paired-viewer list operations (pure; persistence is the caller's).
public enum PairedViewers {
    public static func contains(_ list: [PairedViewer], key: Data) -> Bool {
        list.contains { $0.keyData == key }
    }

    /// Adds or refreshes (same key → new name/date) a viewer.
    public static func adding(_ list: [PairedViewer], name: String, key: Data, at date: Date) -> [PairedViewer] {
        var out = list.filter { $0.keyData != key }
        out.append(PairedViewer(name: PairedViewer.displayName(name), key: key, paired: date))
        return out
    }

    public static func removing(_ list: [PairedViewer], key: String) -> [PairedViewer] {
        list.filter { $0.key.lowercased() != key.lowercased() }
    }
}

/// The two confirmations a pairing needs: the Mac user (menu-bar alert or `glide-host --pair`)
/// and the viewer (PairConfirm). Either "no" ends it; both "yes" pairs.
public struct PairingVote: Equatable {
    public enum Outcome: Equatable { case pending, paired, declinedHere, declinedByViewer }
    public var local: Bool?
    public var viewer: Bool?
    public init() {}
    public var outcome: Outcome {
        if local == false { return .declinedHere }
        if viewer == false { return .declinedByViewer }
        if local == true && viewer == true { return .paired }
        return .pending
    }
}

/// The host's pairing window ("Pair New Viewer…", 2 minutes) and its single pairing slot.
/// Thread-safe. Times are passed in so tests can drive them.
public final class PairingWindow: @unchecked Sendable {
    public static let defaultDuration: TimeInterval = 120
    /// How long one pairing may wait for both confirmations.
    public static let confirmTimeout: TimeInterval = 60

    public enum Claim: Equatable { case granted, closed, busy }

    private let lock = NSLock()
    private var until: Date?
    private var holder: Int?

    public init() {}

    public func open(now: Date = Date(), duration: TimeInterval = defaultDuration) {
        lock.lock(); until = now.addingTimeInterval(duration); lock.unlock()
    }

    public func close() { lock.lock(); until = nil; lock.unlock() }

    public func isOpen(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return until.map { now < $0 } ?? false
    }

    /// Seconds left, nil when closed.
    public func remaining(now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let u = until, now < u else { return nil }
        return u.timeIntervalSince(now)
    }

    public var busyWith: Int? { lock.lock(); defer { lock.unlock() }; return holder }

    /// A viewer asked to pair on session `id`.
    public func claim(_ id: Int, now: Date = Date()) -> Claim {
        lock.lock(); defer { lock.unlock() }
        guard let u = until, now < u else { return .closed }
        if let h = holder, h != id { return .busy }
        holder = id
        return .granted
    }

    /// Session `id` finished pairing. A successful pairing closes the window (one viewer per
    /// "Pair New Viewer…"); a failed one leaves it open for another try.
    public func release(_ id: Int, paired: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard holder == id else { return }
        holder = nil
        if paired { until = nil }
    }
}

/// Host-side rate limiting of failed handshakes / rejected viewers, per IPv4 address or IPv6 /64
/// (mirrors the viewer's `peers::Backoff`): 1 s doubling to 60 s. A blocked address gets
/// HostPreamble status 3 before any DH. Opening the pairing window clears it.
public final class HandshakeBackoff: @unchecked Sendable {
    public static let start: TimeInterval = 1
    public static let max: TimeInterval = 60
    private let lock = NSLock()
    private var state: [String: (failures: Int, until: Date)] = [:]

    public init() {}

    /// Bucket key: IPv4 address, IPv6 /64 prefix, IPv4-mapped IPv6 as IPv4. Strips a zone.
    public static func key(_ address: String) -> String {
        var a = address
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a.hasPrefix("[") && a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
        var v6 = in6_addr()
        if a.contains(":"), inet_pton(AF_INET6, a, &v6) == 1 {
            var b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
            }
            for i in 8..<16 { b[i] = 0 }
            var masked = in6_addr()
            withUnsafeMutableBytes(of: &masked) { $0.copyBytes(from: b) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &masked, &buf, socklen_t(buf.count))
            return String(cString: buf) + "/64"
        }
        return a
    }

    /// Seconds left if `address` must be refused right now.
    public func blocked(_ address: String, now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let s = state[Self.key(address)], now < s.until else { return nil }
        return s.until.timeIntervalSince(now)
    }

    /// Record a failure; returns the block duration.
    @discardableResult
    public func failed(_ address: String, now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(address)
        let n = (state[k]?.failures ?? 0) + 1
        let d = Swift.min(Self.start * pow(2, Double(Swift.min(n - 1, 16))), Self.max)
        state[k] = (n, now.addingTimeInterval(d))
        if state.count > 1024 { state = state.filter { now < $0.value.until.addingTimeInterval(Self.max) } }
        return d
    }

    public func succeeded(_ address: String) {
        lock.lock(); state[Self.key(address)] = nil; lock.unlock()
    }

    public func reset() { lock.lock(); state = [:]; lock.unlock() }
}
