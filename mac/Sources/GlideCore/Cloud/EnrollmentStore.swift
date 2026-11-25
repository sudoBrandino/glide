import Foundation

/// A device's stored Glide Cloud enrollment (docs/ENTERPRISE.md §11.3): `cloud-host.json` or
/// `cloud-viewer.json` in the app's 0700 config folder, mode 0600, next to the static key it is
/// as sensitive as.
///
/// Spec fields: `cloud_url`, `org_id`, `device_id`, `device_token`, `enrolled_at`, and on a viewer
/// `user_token`, `user_token_expires`. Glide also keeps a few display-only fields (org name, device
/// name, the signed-in user) and the last org settings, so the policy (`lan_mode: false`) applies
/// from launch even before the cloud answers.
public struct Enrollment: Codable, Equatable, Sendable {
    public var cloudURL: String
    public var orgId: String
    public var deviceId: String
    public var deviceToken: String
    public var enrolledAt: String
    public var userToken: String?
    public var userTokenExpires: String?
    // Glide extras (display and policy cache; never sent anywhere).
    public var orgName: String?
    public var orgSlug: String?
    public var deviceName: String?
    public var user: CloudUser?
    public var settings: OrgSettings?

    public init(cloudURL: String, orgId: String, deviceId: String, deviceToken: String, enrolledAt: String,
                orgName: String? = nil, orgSlug: String? = nil, deviceName: String? = nil, settings: OrgSettings? = nil) {
        self.cloudURL = cloudURL; self.orgId = orgId; self.deviceId = deviceId; self.deviceToken = deviceToken
        self.enrolledAt = enrolledAt; self.orgName = orgName; self.orgSlug = orgSlug; self.deviceName = deviceName
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case cloudURL = "cloud_url", orgId = "org_id", deviceId = "device_id", deviceToken = "device_token"
        case enrolledAt = "enrolled_at", userToken = "user_token", userTokenExpires = "user_token_expires"
        case orgName = "org_name", orgSlug = "org_slug", deviceName = "device_name", user, settings
    }

    /// Same cloud as the managed `CloudURL` (scheme/host/port/path, case-insensitive host).
    public func isFor(_ url: URL) -> Bool { Enrollment.normalize(cloudURL) == Enrollment.normalize(url.absoluteString) }

    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// The user token, if present and not expired (with a minute of margin).
    public func validUserToken(now: Date = Date()) -> String? {
        guard let t = userToken, !t.isEmpty else { return nil }
        if let exp = CloudTime.parse(userTokenExpires), exp.timeIntervalSince(now) < 60 { return nil }
        return t
    }
}

/// Reads and writes one enrollment file. All writes go through a temporary file created 0600 and
/// renamed over the old one; the folder is created 0700.
public struct EnrollmentStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `cloud-host.json` / `cloud-viewer.json` in `dir`.
    public static func file(for kind: DeviceKind, in dir: URL) -> EnrollmentStore {
        EnrollmentStore(url: dir.appendingPathComponent(kind == .host ? "cloud-host.json" : "cloud-viewer.json"))
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String), unwritable(String)
        public var description: String {
            switch self {
            case let .unreadable(s): return "can't read the enrollment: \(s)"
            case let .unwritable(s): return "can't save the enrollment: \(s)"
            }
        }
    }

    /// nil when there is none. A file that can't be decoded throws (the caller re-enrolls only on
    /// purpose; the device token in it may still be valid).
    public func load() throws -> Enrollment? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Tighten a file someone loosened (it holds a bearer token).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 != 0 {
            chmod(url.path, 0o600)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable("\(url.path): \(error.localizedDescription)") }
        do { return try JSONDecoder().decode(Enrollment.self, from: data) } catch {
            throw Failure.unreadable("\(url.path) is not a valid enrollment (\(error))")
        }
    }

    public func save(_ e: Enrollment) throws {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
                throw Failure.unwritable("\(dir.path): \(error.localizedDescription)")
            }
        }
        let enc = JSONEncoder.cloud
        enc.outputFormatting.insert(.prettyPrinted)
        let data: Data
        do { data = try enc.encode(e) } catch { throw Failure.unwritable("\(error)") }
        let tmp = url.path + ".tmp.\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unwritable("\(tmp): \(String(cString: strerror(errno)))") }
        let written = data.withUnsafeBytes { p -> Int in write(fd, p.baseAddress, p.count) }
        fchmod(fd, 0o600)
        fsync(fd)
        close(fd)
        guard written == data.count else { unlink(tmp); throw Failure.unwritable("\(tmp): short write") }
        guard rename(tmp, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp)
            throw Failure.unwritable("\(url.path): \(why)")
        }
    }

    /// Removes the enrollment (revoked, or signed out of a different cloud). Missing is fine.
    public func wipe() {
        unlink(url.path)
    }

    /// Read-modify-write; no-op when there is no enrollment.
    @discardableResult
    public func update(_ change: (inout Enrollment) -> Void) throws -> Enrollment? {
        guard var e = try load() else { return nil }
        change(&e)
        try save(e)
        return e
    }
}
