import Foundation

/// Received file names are untrusted (PROTOCOL.md §6.3). Same rules as the viewer's
/// `files::sanitize_path`; both are checked against docs/file-transfer-vectors.json.
/// Works on Unicode scalars and UTF-8 bytes, never on Characters (a combining mark after "/"
/// would otherwise hide the separator inside one grapheme).
public enum FileNames {
    public static let maxPathBytes = 4096
    public static let maxDepth = 32
    /// Room for " (9999)" and a "_" prefix under the 255-byte APFS / 255-unit NTFS limit.
    public static let maxComponentBytes = 200

    public enum PathError: Error, CustomStringConvertible, Equatable {
        case empty, tooLong, absolute, tooDeep, emptyComponent, dotComponent
        public var description: String {
            switch self {
            case .empty: return "empty path"
            case .tooLong: return "path too long"
            case .absolute: return "absolute path"
            case .tooDeep: return "too deeply nested"
            case .emptyComponent: return "empty path component"
            case .dotComponent: return "'.' or '..' in path"
            }
        }
    }

    typealias Scalars = [Unicode.Scalar]

    /// Bidi overrides, zero-width and other invisible format characters (extension spoofing).
    static func isFormat(_ v: UInt32) -> Bool {
        v == 0x061C || v == 0xFEFF || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
            || (0x2060...0x2064).contains(v) || (0x2066...0x2069).contains(v)
    }

    static let invalid: Set<UInt32> = Set("\\:*?\"<>|".unicodeScalars.map(\.value))
    static let reserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        for p in ["COM", "LPT"] { for d in Array("0123456789").map(String.init) + ["\u{00B9}", "\u{00B2}", "\u{00B3}"] { s.insert(p + d) } }
        return s
    }()

    static func asciiUpper(_ s: Scalars) -> String {
        var out = String.UnicodeScalarView()
        for c in s { out.append((0x61...0x7A).contains(c.value) ? Unicode.Scalar(c.value - 32)! : c) }
        return String(out)
    }

    static func string(_ s: Scalars) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: s); return String(v) }

    static func trimTrailing(_ s: Scalars) -> Scalars {
        var s = s
        while let l = s.last, l == "." || l == " " { s.removeLast() }
        return s.isEmpty ? ["_"] : s
    }

    static func utf8Len(_ s: Scalars) -> Int { s.reduce(0) { $0 + UTF8.width($1) } }

    /// One received path component -> a name that is safe on macOS and Windows.
    public static func sanitizeComponent(_ c: String) -> String {
        var s: Scalars = c.unicodeScalars.map { ch in
            let v = ch.value
            return (v < 0x20 || v == 0x7F || invalid.contains(v) || isFormat(v)) ? "_" : ch
        }
        s = trimTrailing(s)
        var base = Scalars(s.prefix { $0 != "." })
        while base.last == " " { base.removeLast() }
        if reserved.contains(asciiUpper(base)) { s.insert("_", at: 0) }
        if utf8Len(s) > maxComponentBytes {
            var ext: Scalars = []
            if let i = s.lastIndex(of: "."), i > 0, utf8Len(Scalars(s[i...])) <= 32 { ext = Scalars(s[i...]) }
            var stem = Scalars(s[..<(s.count - ext.count)])
            let budget = maxComponentBytes - utf8Len(ext)
            while utf8Len(stem) > budget { stem.removeLast() }
            s = trimTrailing(stem + ext)
            // Step 5 (§6.3): the cut can expose a device name ("CON" + spaces + "x" -> "CON").
            var cut = Scalars(s.prefix { $0 != "." })
            while cut.last == " " { cut.removeLast() }
            if reserved.contains(asciiUpper(cut)) { s.insert("_", at: 0) }
        }
        return string(s)
    }

    /// A wire path ('/'-separated, relative) -> safe components; throws for paths that must be
    /// refused outright (traversal, absolute, too long / deep).
    public static func sanitizePath(_ p: String) throws -> [String] {
        let b = Array(p.utf8)
        if b.isEmpty { throw PathError.empty }
        if b.count > maxPathBytes { throw PathError.tooLong }
        let isAlpha = { (c: UInt8) in (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
        if b[0] == UInt8(ascii: "/") || b[0] == UInt8(ascii: "\\") || (b.count >= 2 && b[1] == UInt8(ascii: ":") && isAlpha(b[0])) {
            throw PathError.absolute
        }
        let comps = b.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        if comps.count > maxDepth { throw PathError.tooDeep }
        for c in comps {
            if c.isEmpty { throw PathError.emptyComponent }
            if Array(c) == [0x2E] || Array(c) == [0x2E, 0x2E] { throw PathError.dotComponent }
        }
        return comps.map { sanitizeComponent(String(decoding: $0, as: UTF8.self)) }
    }

    /// Collision rename: ("a.txt", 2) -> "a (2).txt"; folders and dotfiles get the suffix at the end.
    public static func withSuffix(_ name: String, _ n: Int, isDir: Bool) -> String {
        if n <= 1 { return name }
        let s = Scalars(name.unicodeScalars)
        if !isDir, let i = s.lastIndex(of: "."), i > 0 {
            return string(Scalars(s[..<i])) + " (\(n))" + string(Scalars(s[i...]))
        }
        return name + " (\(n))"
    }
}

/// Status / reason codes of FileAnswer, FileCancel and FilePullResult (§6).
public enum FileStatus {
    public static let ok: UInt8 = 0
    public static let declined: UInt8 = 1
    public static let tooLarge: UInt8 = 2
    public static let badName: UInt8 = 3
    public static let busy: UInt8 = 4
    public static let noSpace: UInt8 = 5
    public static let io: UInt8 = 6
    public static let cancelled: UInt8 = 7
    public static let verify: UInt8 = 8
    public static let protocolError: UInt8 = 9
    public static let sourceChanged: UInt8 = 10
    public static let nothing: UInt8 = 11

    public static func text(_ s: UInt8) -> String {
        switch s {
        case ok: return "ok"
        case declined: return "declined"
        case tooLarge: return "too large"
        case badName: return "unsafe file name"
        case busy: return "another transfer is in progress"
        case noSpace: return "disk full"
        case io: return "I/O error"
        case cancelled: return "cancelled"
        case verify: return "verification failed"
        case protocolError: return "protocol error"
        case sourceChanged: return "a file changed while it was being sent"
        case nothing: return "nothing to send"
        default: return "error"
        }
    }
}

public struct FileLimits: Equatable, Sendable {
    public var maxTotalBytes: UInt64
    public var maxFiles: Int
    public init(maxTotalBytes: UInt64 = 8 << 30, maxFiles: Int = 10_000) { self.maxTotalBytes = maxTotalBytes; self.maxFiles = maxFiles }
    public func min(_ o: FileLimits) -> FileLimits {
        FileLimits(maxTotalBytes: Swift.min(maxTotalBytes, o.maxTotalBytes), maxFiles: Swift.min(maxFiles, o.maxFiles))
    }
}

/// Offer modification times (§6.2): applied only within 1 ms ... 9999-12-31T23:59:59.999Z.
public enum FileTimes {
    public static let maxMs: Int64 = 253_402_300_799_999
    /// (seconds, microseconds) to apply, or nil (unknown, negative or absurd: ignored).
    public static func split(_ ms: Int64) -> (sec: Int, usec: Int32)? {
        guard ms >= 1, ms <= maxMs else { return nil }
        return (Int(ms / 1000), Int32(ms % 1000) * 1000)
    }
}

public struct FileFailure: Error, CustomStringConvertible {
    public var status: UInt8
    public var detail: String
    public init(_ status: UInt8, _ detail: String) { self.status = status; self.detail = detail }
    public var description: String { detail }
}

public enum FileOffers {
    public static func isHostId(_ id: UInt32) -> Bool { id & FileMessage.hostIdBit != 0 }

    /// Checks a received offer; returns the sanitized components of every file.
    public static func validate(id: UInt32, total: UInt64, files: [FileEntry], limits: FileLimits, fromHost: Bool) -> Result<[[String]], FileFailure> {
        if id == 0 || isHostId(id) != fromHost { return .failure(FileFailure(FileStatus.protocolError, "transfer id outside the sender's range")) }
        if files.isEmpty { return .failure(FileFailure(FileStatus.protocolError, "empty offer")) }
        var sum: UInt64 = 0
        for f in files {
            let (v, o) = sum.addingReportingOverflow(f.size)
            if o { return .failure(FileFailure(FileStatus.protocolError, "file sizes don't add up to the total")) }
            sum = v
        }
        if sum != total { return .failure(FileFailure(FileStatus.protocolError, "file sizes don't add up to the total")) }
        if files.count > limits.maxFiles { return .failure(FileFailure(FileStatus.tooLarge, "\(files.count) files (limit \(limits.maxFiles))")) }
        if total > limits.maxTotalBytes {
            return .failure(FileFailure(FileStatus.tooLarge, "\(byteText(total)) (limit \(byteText(limits.maxTotalBytes)))"))
        }
        var rel: [[String]] = []
        for (i, f) in files.enumerated() {
            do { rel.append(try FileNames.sanitizePath(f.path)) } catch { return .failure(FileFailure(FileStatus.badName, "file \(i + 1): \(error)")) }
        }
        // A name can't be both a file and a folder (case-insensitively).
        if let c = fileFolderConflict(rel) {
            return .failure(FileFailure(FileStatus.badName, "'\(c.joined(separator: "/"))' is both a file and a folder"))
        }
        return .success(rel)
    }

    /// The first file whose path is also a folder of another file (case-insensitively), if any.
    /// Sorted keys plus one binary search per file: O(n log n). Collecting every folder prefix in
    /// a set costs O(depth² · length) per file, which a hostile 10 000-file offer of 4 KiB paths
    /// turns into gigabytes of strings.
    static func fileFolderConflict(_ rel: [[String]]) -> [String]? {
        // Compare UTF-8 bytes: String's < is Unicode-aware and not a plain prefix order.
        let keys = rel.enumerated().map { (Array($0.element.joined(separator: "/").lowercased().utf8), $0.offset) }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }
        for (k, i) in keys {
            let dir = k + [UInt8(ascii: "/")]
            var lo = 0, hi = keys.count
            while lo < hi { let mid = (lo + hi) / 2; if keys[mid].0.lexicographicallyPrecedes(dir) { lo = mid + 1 } else { hi = mid } }
            if lo < keys.count, keys[lo].0.starts(with: dir) { return rel[i] }
        }
        return nil
    }

    public static func byteText(_ n: UInt64) -> String {
        if n < 1000 { return "\(n) bytes" }
        var v = Double(n); var i = 0
        let u = ["bytes", "KB", "MB", "GB", "TB"]
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
        return v < 10 ? String(format: "%.1f %@", v, u[i]) : String(format: "%.0f %@", v, u[i])
    }

    public static func fileText(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}
