import Foundation

/// Little-endian byte writer.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    public mutating func bytes(_ d: [UInt8]) { data.append(contentsOf: d) }
    public mutating func str(_ s: String) {
        let b = Data(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(b.count))
        data.append(b)
    }
}

public enum WireError: Error, CustomStringConvertible {
    case truncated
    case badMagic
    case badVersion(UInt16)
    case unknownMessage(UInt8)
    case decryptFailed
    case recordTooLarge(Int)
    case closed

    public var description: String {
        switch self {
        case .truncated: return "truncated message"
        case .badMagic: return "bad handshake magic"
        case .badVersion(let v): return "unsupported protocol version \(v)"
        case .unknownMessage(let t): return String(format: "unknown message type 0x%02x", t)
        case .decryptFailed: return "decrypt failed (wrong password?)"
        case .recordTooLarge(let n): return "record too large (\(n) bytes)"
        case .closed: return "connection closed"
        }
    }
}

/// Little-endian byte reader over a Data slice.
public struct ByteReader {
    private let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard remaining >= n else { throw WireError.truncated }
        let d = data[offset ..< offset + n]
        offset += n
        return d
    }

    private mutating func le<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let d = try take(MemoryLayout<T>.size)
        var v: T = 0
        for (i, b) in d.enumerated() { v |= T(b) << (8 * i) }
        return v
    }

    public mutating func u8() throws -> UInt8 { try le(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try le(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try le(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try le(UInt64.self) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func rest() -> Data { let d = Data(data[offset...]); offset = data.endIndex; return d }
    public mutating func str() throws -> String {
        let n = Int(try u16())
        return String(decoding: try take(n), as: UTF8.self)
    }
}

public extension Data {
    init?(hex: String) {
        var out = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Monotonic host clock in microseconds (same timebase as CoreMedia host time / mach_absolute_time).
public func hostTimeMicros() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000
}
