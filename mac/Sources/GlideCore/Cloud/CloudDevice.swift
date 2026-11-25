import Foundation

/// One app's Glide Cloud membership (docs/ENTERPRISE.md §5.1, §6.4, §7, §11): managed config →
/// stored enrollment or `POST /v1/enroll` → hub connection, org settings (cached in the
/// enrollment so they apply from launch), heartbeat, client audit, and revocation. UI-free;
/// glide-host and glide-viewer show its `Status` and act on its events. All state is on `queue`;
/// callbacks run there.
public final class CloudDevice: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// No `CloudURL` in the managed configuration.
        case unmanaged
        case enrolling
        /// Enrolled; `connected` = the hub socket is up.
        case enrolled(connected: Bool)
        /// Can't enroll or connect right now (retrying unless `final`).
        case failed(String, final: Bool)
        /// The cloud revoked this device (or its token stopped working); the enrollment was deleted.
        case revoked(String)
    }

    public struct Status: Equatable, Sendable {
        public var state: State = .unmanaged
        public var cloudURL: URL?
        public var orgName: String?
        public var orgSlug: String?
        public var deviceName: String?
        public var deviceId: String?
        public var enrolledAt: String?
        /// Last known org settings (nil when not enrolled).
        public var settings: OrgSettings?
        public var policy: ManagedPolicy
        /// Problems in the managed configuration.
        public var configProblems: [String] = []
        public var disableLANMode = false

        public var isEnrolled: Bool { if case .enrolled = state { return true }; return false }
        /// Managed by an org (enrolled, or enrolling from a configuration profile).
        public var isManaged: Bool { state != .unmanaged }

        /// "Managed by Example Corp" / "Connecting to Glide Cloud…" for menus and Settings.
        public var summary: String {
            switch state {
            case .unmanaged: return "Not managed"
            case .enrolling: return "Enrolling with Glide Cloud…"
            case let .enrolled(connected): return "Managed by \(orgName ?? "your organization")" + (connected ? "" : " (offline)")
            case let .failed(why, _): return "Glide Cloud: \(why)"
            case let .revoked(why): return "Removed from \(orgName ?? "the organization")" + (why.isEmpty ? "" : " (\(why))")
            }
        }
    }

    public let kind: DeviceKind
    public let queue = DispatchQueue(label: "glide.cloud.device")
    public let store: EnrollmentStore
    public let audit: AuditReporter
    public private(set) var status: Status
    public private(set) var client: CloudClient?

    public var onStatus: (Status) -> Void = { _ in }
    /// Hub events other than `connected`, `settings` and `revoked` (handled here first).
    public var onHubEvent: (HubEvent) -> Void = { _ in }
    /// The device was revoked: end managed sessions (the enrollment is already deleted).
    public var onRevoked: (String) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }

    private let publicKey: Data
    private let config: ManagedConfig
    private let appVersion: String
    private let transport: CloudHTTPTransport
    private let wsFactory: CloudWebSocketFactory
    private var hub: HubClient?
    private var enrollBackoff = CloudBackoff(initial: 5, max: 600)
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastHeartbeat: Date?
    private var started = false

    public init(kind: DeviceKind, publicKey: Data, store: EnrollmentStore, config: ManagedConfig, appVersion: String = GlideVersion.version,
                transport: CloudHTTPTransport = URLSessionTransport.shared, wsFactory: @escaping CloudWebSocketFactory = URLSessionWebSocket.factory) {
        self.kind = kind
        self.publicKey = publicKey
        self.store = store
        self.config = config
        self.appVersion = appVersion
        self.transport = transport
        self.wsFactory = wsFactory
        audit = AuditReporter(send: { _ in throw CloudError.invalid("not enrolled") })
        status = Status(policy: ManagedPolicy(settings: nil, disableLANMode: config.disableLANMode, appVersion: appVersion))
        status.cloudURL = config.cloudURL
        status.configProblems = config.problems
        status.disableLANMode = config.disableLANMode
        // The cached settings apply right away (before any network), so `lan_mode: false` holds
        // from launch.
        if let url = config.cloudURL, let e = try? store.load(), e.isFor(url) { apply(enrollment: e, state: .enrolled(connected: false)) }
        audit.send = { [weak self] b in
            guard let c = self?.queue.sync(execute: { self?.client }) else { throw CloudError.invalid("not enrolled") }
            try await c.audit(b)
        }
    }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            guard let url = config.cloudURL else {
                setState(.unmanaged)
                return
            }
            let stored: Enrollment?
            do { stored = try store.load() } catch {
                log("cloud: \(error)")
                stored = nil
            }
            if let e = stored, e.isFor(url) {
                apply(enrollment: e, state: .enrolled(connected: false))
                connect(e)
            } else {
                if stored != nil { log("cloud: the stored enrollment is for another cloud (\(stored!.cloudURL)); enrolling with \(url.absoluteString)") }
                enroll()
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            hub?.stop(); hub = nil
            heartbeatTimer?.cancel(); heartbeatTimer = nil
            started = false
        }
    }

    /// Sends a hub frame (host: `session_answer`, `session_state`).
    public func send(_ f: HubClientFrame) { queue.async { [self] in hub?.send(f) } }

    /// The current enrollment as stored (viewer: user token fields).
    public func enrollment() -> Enrollment? { try? store.load() }

    /// Read-modify-write of the stored enrollment (viewer: the user token).
    public func updateEnrollment(_ change: @escaping (inout Enrollment) -> Void) {
        queue.async { [self] in
            do { try store.update(change) } catch { log("cloud: \(error)") }
        }
    }

    /// The device token stopped working on a call (401 from a device endpoint): same as `revoked`.
    public func tokenRejected() { queue.async { [self] in revoked("unauthorized") } }

    // MARK: Enrollment

    private func enroll() {
        guard let url = config.cloudURL else { return }
        guard let token = config.enrollmentToken else {
            setState(.failed("no enrollment token in the managed settings", final: true))
            return
        }
        setState(.enrolling)
        let req = EnrollRequest(enrollmentToken: token, kind: kind, publicKey: publicKey.hex,
                                name: config.deviceName ?? DeviceFacts.computerName, osVersion: DeviceFacts.osVersion,
                                appVersion: appVersion, tags: config.tags.isEmpty ? nil : config.tags)
        let c = CloudClient(baseURL: url, transport: transport)
        Task {
            do {
                let r = try await c.enroll(req)
                queue.async { [self] in enrolled(r, url: url, name: req.name) }
            } catch let e as CloudError {
                queue.async { [self] in enrollFailed(e) }
            } catch {
                queue.async { [self] in enrollFailed(.transport("\(error)")) }
            }
        }
    }

    private func enrolled(_ r: EnrollResponse, url: URL, name: String) {
        guard started else { return }
        var e = Enrollment(cloudURL: url.absoluteString, orgId: r.org.id, deviceId: r.deviceId, deviceToken: r.deviceToken,
                           enrolledAt: CloudTime.format(Date()), orgName: r.org.name, orgSlug: r.org.slug, deviceName: name, settings: r.settings)
        // Keep a viewer's sign-in across a re-enrollment with the same key? No: a new device token
        // means a new binding, and the user token is bound to the old one (§5.2).
        e.userToken = nil
        do { try store.save(e) } catch {
            log("cloud: \(error)")
            setState(.failed("\(error)", final: true))
            return
        }
        log("cloud: enrolled with \(r.org.name) as \(r.deviceId)")
        enrollBackoff.reset()
        apply(enrollment: e, state: .enrolled(connected: false))
        connect(e)
    }

    private func enrollFailed(_ e: CloudError) {
        guard started else { return }
        switch e.code {
        case "device_revoked":
            log("cloud: enrollment refused: this device was revoked")
            setState(.revoked("revoked by an administrator"))
            return
        case "invalid_token", "token_expired", "token_exhausted", "invalid_enrollment_token":
            log("cloud: enrollment refused: \(e)")
            setState(.failed("the enrollment token was refused (\(e.code ?? ""))", final: true))
            return
        default: break
        }
        let delay = enrollBackoff.next()
        log("cloud: enrollment failed (\(e)); retrying in \(Int(delay)) s")
        setState(.failed("can't enroll: \(e)", final: false))
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            if started, case .failed(_, false) = status.state { enroll() }
        }
    }

    // MARK: Hub

    private func connect(_ e: Enrollment) {
        guard let url = URL(string: e.cloudURL) else { return }
        let c = CloudClient(baseURL: url, deviceToken: e.deviceToken, userToken: e.validUserToken(), transport: transport)
        client = c
        let h = HubClient(request: { try c.hubRequest() }, factory: wsFactory, queue: queue)
        h.onEvent = { [weak self] ev in self?.hubEvent(ev) }
        hub = h
        h.start()
    }

    private func hubEvent(_ ev: HubEvent) {
        switch ev {
        case let .connected(_, settings):
            setSettings(settings)
            setState(.enrolled(connected: true))
            refreshDevice()
            heartbeatIfDue()
        case let .settings(s):
            setSettings(s)
            onHubEvent(ev)
        case let .revoked(reason):
            revoked(reason)
        case let .disconnected(retryIn, why):
            if status.isEnrolled { setState(.enrolled(connected: false)) }
            log("cloud: hub disconnected (\(why)); reconnecting in \(Int(retryIn.rounded())) s")
            onHubEvent(ev)
        case .offer, .cancel:
            onHubEvent(ev)
        }
    }

    private func revoked(_ reason: String) {
        guard status.state != .unmanaged else { return }
        log("cloud: this device is no longer enrolled (\(reason)); deleting the enrollment")
        hub?.stop(); hub = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        client = nil
        store.wipe()
        status.settings = nil
        status.deviceId = nil
        status.policy = ManagedPolicy(settings: nil, disableLANMode: config.disableLANMode, appVersion: appVersion)
        setState(.revoked(reason == "unauthorized" ? "its token is no longer valid" : reason))
        onRevoked(reason)
    }

    private func setSettings(_ s: OrgSettings) {
        guard s != status.settings else { return }
        status.settings = s
        status.policy = ManagedPolicy(settings: s, disableLANMode: config.disableLANMode, appVersion: appVersion)
        audit.includeFileNames = status.policy.auditFileNames
        do { try store.update { $0.settings = s } } catch { log("cloud: \(error)") }
        log("cloud: org settings: LAN mode \(s.lanMode ? "on" : "off"), local pairing \(s.allowLocalPairing ? "allowed" : "off"), minimum version \(s.minAppVersion ?? "none")")
        onStatus(status)
    }

    /// Org and device names (they can change in the console).
    private func refreshDevice() {
        guard let c = client else { return }
        Task {
            guard let d = try? await c.device() else { return }
            queue.async { [self] in
                guard client === c else { return }
                status.orgName = d.org.name
                status.orgSlug = d.org.slug
                status.deviceName = d.name
                _ = try? store.update { $0.orgName = d.org.name; $0.orgSlug = d.org.slug; $0.deviceName = d.name }
                setSettings(d.settings)
                onStatus(status)
            }
        }
    }

    private func heartbeatIfDue() {
        if heartbeatTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
            t.setEventHandler { [weak self] in self?.heartbeat() }
            t.resume()
            heartbeatTimer = t
        }
        if lastHeartbeat == nil { heartbeat() }
    }

    private func heartbeat() {
        guard let c = client else { return }
        lastHeartbeat = Date()
        let r = HeartbeatRequest(appVersion: appVersion, osVersion: DeviceFacts.osVersion)
        Task { try? await c.heartbeat(r) }
    }

    // MARK: Status

    private func apply(enrollment e: Enrollment, state: State) {
        status.orgName = e.orgName
        status.orgSlug = e.orgSlug
        status.deviceName = e.deviceName
        status.deviceId = e.deviceId
        status.enrolledAt = e.enrolledAt
        status.settings = e.settings
        status.policy = ManagedPolicy(settings: e.settings, disableLANMode: config.disableLANMode, appVersion: appVersion)
        audit.includeFileNames = status.policy.auditFileNames
        status.state = state
    }

    private func setState(_ s: State) {
        status.state = s
        onStatus(status)
    }
}
