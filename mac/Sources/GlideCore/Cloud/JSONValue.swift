import Foundation

/// Any JSON value, for the few Glide Cloud fields whose shape is open (audit `detail`, the hub's
/// `ping.t`, which the device echoes back unchanged in `pong`). docs/ENTERPRISE.md §6.
public enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            // Whole numbers go out without a fraction (`1732550400`, not `1732550400.0`).
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public var description: String {
        guard let d = try? JSONEncoder.cloud.encode(self) else { return "?" }
        return String(decoding: d, as: UTF8.self)
    }

    public static func int<I: BinaryInteger>(_ v: I) -> JSONValue { .number(Double(v)) }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var doubleValue: Double? { if case let .number(n) = self { return n }; return nil }
}

public extension JSONEncoder {
    /// Glide Cloud bodies: compact, stable key order (tests compare bytes).
    static var cloud: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// RFC 3339 UTC times (ENTERPRISE.md §6: "Times are RFC 3339 UTC strings").
public enum CloudTime {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
