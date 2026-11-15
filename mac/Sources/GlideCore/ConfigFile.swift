import Foundation

/// JSON config files (host.json, probe.json): read, write atomically, and read-modify-write
/// without ever replacing a file that exists but can't be decoded. Such a file still holds what
/// the user cares about (paired viewers, pinned host keys); writing defaults over it would lose
/// that for good, so a change is refused with an error the caller shows instead.
public enum ConfigFile {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The file exists but couldn't be read (permissions, a folder, I/O).
        case unreadable(path: String, reason: String)
        /// The file was read but isn't valid for this version (bad JSON, a value of the wrong type).
        case undecodable(path: String, reason: String)
        case unwritable(path: String, reason: String)

        public var path: String {
            switch self { case let .unreadable(p, _), let .undecodable(p, _), let .unwritable(p, _): return p }
        }

        public var description: String {
            switch self {
            case let .unreadable(p, r): return "\(p) can't be read (\(r))"
            case let .undecodable(p, r): return "\(p) is not valid (\(r))"
            case let .unwritable(p, r): return "\(p) can't be written (\(r))"
            }
        }
    }

    /// The decoded file; nil when there is no file. Throws `Failure` for any other problem.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return nil }
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            throw Failure.unreadable(path: url.path, reason: (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ns.localizedDescription)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw Failure.undecodable(path: url.path, reason: describe(error))
        }
    }

    /// Writes `value` as pretty, key-sorted JSON (mode 0600) through a temporary file and a rename,
    /// so a reader never sees half a file.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try enc.encode(value) } catch { throw Failure.unwritable(path: url.path, reason: "\(error)") }
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unwritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        guard rename(tmp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(tmp.path)
            throw Failure.unwritable(path: url.path, reason: reason)
        }
    }

    /// Read-modify-write: the current file (or `defaults()` when there is none), changed by
    /// `change`, written back and returned. Throws, writing nothing, when the existing file can't be
    /// read or decoded.
    @discardableResult
    public static func update<T: Codable>(_ url: URL, defaults: () -> T, _ change: (inout T) throws -> Void) throws -> T {
        var value = try read(T.self, from: url) ?? defaults()
        try change(&value)
        try write(value, to: url)
        return value
    }

    /// A short, readable reason for a decoding error: where in the file and what was wrong.
    public static func describe(_ error: Error) -> String {
        func at(_ path: [CodingKey]) -> String {
            let p = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "" : "\(p): "
        }
        guard let e = error as? DecodingError else { return "\(error)" }
        switch e {
        case let .typeMismatch(type, c): return "\(at(c.codingPath))expected \(type)"
        case let .valueNotFound(type, c): return "\(at(c.codingPath))missing \(type) value"
        case let .keyNotFound(key, c): return "\(at(c.codingPath + [key]))missing"
        case let .dataCorrupted(c):
            let underlying = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "\(at(c.codingPath))\(underlying ?? c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}
