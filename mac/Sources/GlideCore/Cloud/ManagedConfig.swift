import CoreFoundation
import Foundation

/// Where managed settings come from. The apps read the preference domain `dev.brandino.glide`
/// (ENTERPRISE.md §11.1), which a configuration profile fills through `/Library/Managed
/// Preferences`; tests pass a dictionary.
public protocol ManagedConfigSource {
    func value(forKey key: String) -> Any?
    /// True when an administrator set `key` (a configuration profile), not a user or a process
    /// writing ordinary preferences (ENTERPRISE.md §6.7).
    func isForced(_ key: String) -> Bool
}

/// `CFPreferencesCopyAppValue` in a preference domain (sees managed preferences first).
public struct PreferencesSource: ManagedConfigSource {
    public static let domain = "dev.brandino.glide"
    public let domain: String

    public init(domain: String = PreferencesSource.domain) { self.domain = domain }

    public func value(forKey key: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    /// True when an administrator forces `key` (a configuration profile).
    public func isForced(_ key: String) -> Bool { CFPreferencesAppValueIsForced(key as CFString, domain as CFString) }
}

/// A fixed set of values (tests). `forced`: the keys an administrator set; nil = every key
/// (as if all came from a configuration profile).
public struct DictionarySource: ManagedConfigSource {
    public var values: [String: Any]
    public var forced: Set<String>?
    public init(_ values: [String: Any], forced: Set<String>? = nil) { self.values = values; self.forced = forced }
    public func value(forKey key: String) -> Any? { values[key] }
    public func isForced(_ key: String) -> Bool { forced?.contains(key) ?? (values[key] != nil) }
}

/// The managed configuration (ENTERPRISE.md §11.1, §6.7). A device is configured for Glide Cloud
/// when both `CloudURL` and `EnrollmentToken` are valid. Those (and `DeviceName` and `Tags`, which
/// go into the enrollment) count only when an administrator forced them; a value a user or another
/// process wrote to ordinary preferences is ignored. `DisableLANMode` is read from anywhere: it
/// can only make things stricter.
public struct ManagedConfig: Equatable, Sendable {
    public var cloudURL: URL?
    public var enrollmentToken: String?
    public var deviceName: String?
    public var tags: [String]
    /// Local override: LAN mode off whatever the org says (it can only be stricter, §7).
    public var disableLANMode: Bool
    /// Why a value present in the domain was ignored (shown in logs and Settings).
    public var problems: [String]

    public init(cloudURL: URL? = nil, enrollmentToken: String? = nil, deviceName: String? = nil, tags: [String] = [],
                disableLANMode: Bool = false, problems: [String] = []) {
        self.cloudURL = cloudURL; self.enrollmentToken = enrollmentToken; self.deviceName = deviceName
        self.tags = tags; self.disableLANMode = disableLANMode; self.problems = problems
    }

    public static let keys = (cloudURL: "CloudURL", enrollmentToken: "EnrollmentToken", deviceName: "DeviceName", tags: "Tags",
                              disableLANMode: "DisableLANMode")

    /// Enough to enroll (or to keep using a stored enrollment for this cloud).
    public var isCloudConfigured: Bool { cloudURL != nil && enrollmentToken != nil }

    public static func read(_ source: ManagedConfigSource = PreferencesSource()) -> ManagedConfig {
        var c = ManagedConfig()
        // Only administrator-set values (a configuration profile) for what enrolls this Mac.
        func managed(_ key: String) -> Any? {
            guard let v = source.value(forKey: key) else { return nil }
            guard source.isForced(key) else {
                c.problems.append("\(key) ignored: not set by a configuration profile")
                return nil
            }
            return v
        }
        if let raw = managed(keys.cloudURL) {
            if let s = raw as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                switch parseCloudURL(s) {
                case let .success(u): c.cloudURL = u
                case let .failure(why): c.problems.append("CloudURL ignored: \(why)")
                }
            } else {
                c.problems.append("CloudURL ignored: not a string")
            }
        }
        if let raw = managed(keys.enrollmentToken) {
            let t = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if t.isEmpty || t.count > 512 || t.contains(where: { $0.isWhitespace || $0.isNewline }) {
                c.problems.append("EnrollmentToken ignored: empty, too long or contains spaces")
            } else {
                c.enrollmentToken = t
            }
        }
        if let raw = managed(keys.deviceName) as? String {
            let n = clean(raw, max: 64)
            if !n.isEmpty { c.deviceName = n }
        }
        if let raw = managed(keys.tags) {
            if let a = raw as? [Any] {
                var seen = Set<String>()
                for case let s as String in a {
                    let t = clean(s, max: 64)
                    if !t.isEmpty, seen.insert(t.lowercased()).inserted { c.tags.append(t) }
                }
                if c.tags.count > 32 { c.tags = Array(c.tags.prefix(32)); c.problems.append("Tags: only the first 32 are used") }
            } else if let s = raw as? String {
                // A single string where an array was expected: one tag.
                let t = clean(s, max: 64)
                if !t.isEmpty { c.tags = [t] }
            } else {
                c.problems.append("Tags ignored: not an array of strings")
            }
        }
        c.disableLANMode = boolValue(source.value(forKey: keys.disableLANMode)) ?? false
        return c
    }

    /// An origin (§6.7): `https://host[:port]`, no path (a lone `/` is allowed), query, fragment
    /// or user info. Plain `http` only when the host is a loopback IP address (a development cloud
    /// on this machine): tokens must never cross a network unencrypted. Returns the origin without
    /// the trailing slash.
    public static func parseCloudURL(_ raw: String) -> Result<URL, CloudURLProblem> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else {
            return .failure(.notAURL)
        }
        guard c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else {
            return .failure(.extraParts)
        }
        switch scheme {
        case "https": break
        case "http" where isLoopback(host): break
        default: return .failure(.notHTTPS)
        }
        var o = URLComponents()
        o.scheme = scheme
        o.percentEncodedHost = c.percentEncodedHost
        o.port = c.port
        guard let u = o.url else { return .failure(.notAURL) }
        return .success(u)
    }

    public enum CloudURLProblem: Error, Equatable, CustomStringConvertible {
        case notAURL, notHTTPS, extraParts
        public var description: String {
            switch self {
            case .notAURL: return "not a URL"
            case .notHTTPS: return "must start with https://"
            case .extraParts: return "must be an origin only (https://host[:port]), without a path, user name, query or fragment"
            }
        }
    }

    /// The host parses as a loopback IP address: 127.0.0.0/8 or ::1 (`127.example.com` and
    /// `localhost` are names, not loopback addresses).
    public static func isLoopback(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { b in b.prefix(15).allSatisfy { $0 == 0 } && b[15] == 1 }
        }
        return false
    }

    /// The CloudText rules (controls, bidi and format characters, separators, tag characters and
    /// variation selectors removed, whitespace collapsed, trimmed), at most `max` characters.
    public static func clean(_ s: String, max: Int) -> String { CloudText.clean(s, max: max) }

    static func boolValue(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            switch s.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }
}
