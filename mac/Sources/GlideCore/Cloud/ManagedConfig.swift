import CoreFoundation
import Foundation

/// Where managed settings come from. The apps read the preference domain `dev.brandino.glide`
/// (ENTERPRISE.md §11.1), which a configuration profile fills through `/Library/Managed
/// Preferences`; tests pass a dictionary.
public protocol ManagedConfigSource {
    func value(forKey key: String) -> Any?
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

/// A fixed set of values (tests, `GLIDE_CLOUD_*` development overrides).
public struct DictionarySource: ManagedConfigSource {
    public var values: [String: Any]
    public init(_ values: [String: Any]) { self.values = values }
    public func value(forKey key: String) -> Any? { values[key] }
}

/// The managed configuration (ENTERPRISE.md §11.1). A device is configured for Glide Cloud when
/// both `CloudURL` and `EnrollmentToken` are valid; `DisableLANMode` applies on its own.
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
        if let raw = source.value(forKey: keys.cloudURL) {
            if let s = raw as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                switch parseCloudURL(s) {
                case let .success(u): c.cloudURL = u
                case let .failure(why): c.problems.append("CloudURL ignored: \(why)")
                }
            } else {
                c.problems.append("CloudURL ignored: not a string")
            }
        }
        if let raw = source.value(forKey: keys.enrollmentToken) {
            let t = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if t.isEmpty || t.count > 512 || t.contains(where: { $0.isWhitespace || $0.isNewline }) {
                c.problems.append("EnrollmentToken ignored: empty, too long or contains spaces")
            } else {
                c.enrollmentToken = t
            }
        }
        if let raw = source.value(forKey: keys.deviceName) as? String {
            let n = clean(raw, max: 64)
            if !n.isEmpty { c.deviceName = n }
        }
        if let raw = source.value(forKey: keys.tags) {
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

    /// `https://host[:port][/base]`. Plain `http` only for a loopback host (a development cloud
    /// on this machine): tokens must never cross a network unencrypted.
    public static func parseCloudURL(_ raw: String) -> Result<URL, CloudURLProblem> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else {
            return .failure(.notAURL)
        }
        guard c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return .failure(.extraParts) }
        switch scheme {
        case "https": break
        case "http" where isLoopback(host): break
        case "http": return .failure(.notHTTPS)
        default: return .failure(.notHTTPS)
        }
        guard let u = c.url else { return .failure(.notAURL) }
        return .success(u)
    }

    public enum CloudURLProblem: Error, Equatable, CustomStringConvertible {
        case notAURL, notHTTPS, extraParts
        public var description: String {
            switch self {
            case .notAURL: return "not a URL"
            case .notHTTPS: return "must start with https://"
            case .extraParts: return "must not contain a user name, query or fragment"
            }
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasPrefix("127.")
    }

    /// Control characters removed, trimmed, at most `max` characters.
    static func clean(_ s: String, max: Int) -> String {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) : t
    }

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
