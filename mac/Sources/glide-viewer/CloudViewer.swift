import AppKit
import CryptoKit
import Foundation
import GlideCore
import Network

/// Managed mode on the Mac viewer (docs/ENTERPRISE.md): the Glide Cloud enrollment, the user's
/// sign-in (device authorization grant, §5.2), the hosts the user may reach (§6.2), and starting
/// a session (`POST /v1/sessions` → relay → loopback bridge). Main-thread owned.
final class ManagedViewer: @unchecked Sendable {
    static let shared = ManagedViewer()
    /// Posted on the main thread whenever status, sign-in or the host list changed.
    static let changed = Notification.Name("GlideCloudChanged")

    private(set) var device: CloudDevice?
    private(set) var status: CloudDevice.Status?
    private(set) var user: CloudUser?
    private(set) var hosts: [CloudHost] = []
    private(set) var hostsError: String?
    private(set) var refreshing = false
    private var config = ManagedConfig()

    var isManaged: Bool { status?.isManaged ?? false }
    var isEnrolled: Bool { status?.isEnrolled ?? false }
    var isSignedIn: Bool { user != nil && device?.client?.userToken != nil }
    var orgName: String { status?.orgName ?? "your organization" }

    var policy: ManagedPolicy {
        status?.policy ?? ManagedPolicy(settings: nil, disableLANMode: config.disableLANMode, appVersion: GlideVersion.version)
    }

    /// Why LAN connections are refused, or nil when they are allowed.
    var lanBlockedReason: String? {
        guard !policy.lanAllowed else { return nil }
        return ManagedPolicy.lanOffReason(settings: status?.settings, disableLANMode: config.disableLANMode, orgName: status?.orgName) ?? "turned off"
    }

    func prepare(identity: Curve25519.KeyAgreement.PrivateKey) {
        config = ManagedConfig.read()
        for p in config.problems { print("cloud: managed settings: \(p)") }
        guard config.cloudURL != nil else { return }
        let d = CloudDevice(kind: .viewer, publicKey: identity.publicKey.rawRepresentation,
                            store: EnrollmentStore.file(for: .viewer, in: ViewerPaths.directory), config: config)
        d.log = { print($0) }
        d.onStatus = { [weak self] st in DispatchQueue.main.async { self?.statusChanged(st) } }
        d.onRevoked = { [weak self] _ in DispatchQueue.main.async { self?.signedOutLocally() } }
        device = d
        status = d.status
        if let e = d.enrollment(), e.validUserToken() != nil { user = e.user }
        d.start()
    }

    private func statusChanged(_ st: CloudDevice.Status) {
        let wasEnrolled = isEnrolled
        status = st
        if st.isEnrolled, !wasEnrolled, let e = device?.enrollment() {
            user = e.validUserToken() != nil ? e.user : nil
            if user != nil { refreshHosts() }
        }
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }

    // MARK: Sign-in (§5.2)

    /// Starts the device authorization grant. `progress` gets the code to show; `done` the outcome.
    func signIn(progress: @escaping (DeviceAuthStart) -> Void, isCancelled: @escaping () -> Bool, done: @escaping (String?) -> Void) {
        guard let d = device, let c = d.client, isEnrolled else { done("This Mac isn't enrolled with \(orgName) yet."); return }
        Task {
            let start: DeviceAuthStart
            do { start = try await c.deviceAuthStart() } catch {
                let e = error as? CloudError
                if e?.isUnauthorized == true { d.tokenRejected() }
                await MainActor.run { done("Couldn't start signing in: \(e?.description ?? "\(error)")") }
                return
            }
            await MainActor.run { progress(start) }
            let r = await DeviceAuthPoll.run(client: c, start: start, isCancelled: isCancelled)
            await MainActor.run {
                switch r {
                case let .success(t):
                    self.signedIn(t, client: c)
                    done(nil)
                case let .failure(e):
                    done(isCancelled() ? nil : e.description)
                }
            }
        }
    }

    private func signedIn(_ t: DeviceTokenResponse, client c: CloudClient) {
        c.userToken = t.userToken
        user = t.user
        let exp = CloudTime.format(Date().addingTimeInterval(TimeInterval(max(t.expiresIn, 60))))
        device?.updateEnrollment { e in
            e.userToken = t.userToken
            e.userTokenExpires = exp
            e.user = t.user
        }
        print("cloud: signed in as \(t.user.label)")
        post()
        refreshHosts()
    }

    func signOut() {
        if let c = device?.client, c.userToken != nil { Task { try? await c.signOut() } }
        signedOutLocally()
        print("cloud: signed out")
    }

    /// Forgets the user token (sign-out, expiry, a 401 on a user call).
    private func signedOutLocally() {
        device?.client?.userToken = nil
        device?.updateEnrollment { e in e.userToken = nil; e.userTokenExpires = nil; e.user = nil }
        user = nil
        hosts = []
        post()
    }

    /// A user call got 401: the user token is gone; if the device token fails too, the device was
    /// revoked (CloudDevice wipes the enrollment).
    private func userCallUnauthorized() {
        signedOutLocally()
        guard let d = device, let c = d.client else { return }
        Task {
            do { _ = try await c.device() } catch let e as CloudError where e.isUnauthorized { d.tokenRejected() } catch {}
        }
    }

    // MARK: Hosts (§6.2)

    func refreshHosts() {
        guard isSignedIn, !refreshing, let c = device?.client else { return }
        refreshing = true
        Task {
            do {
                let h = try await c.hosts()
                await MainActor.run {
                    self.refreshing = false
                    self.hosts = h.sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
                    self.hostsError = nil
                    self.post()
                }
            } catch {
                let e = error as? CloudError
                await MainActor.run {
                    self.refreshing = false
                    if e?.isUnauthorized == true { self.userCallUnauthorized(); return }
                    self.hostsError = e?.description ?? "\(error)"
                    self.post()
                }
            }
        }
    }

    // MARK: Sessions (§5.3)

    /// `POST /v1/sessions`; waits for the host's answer (up to 60 s with approval).
    func createSession(_ host: CloudHost, viewOnly: Bool) async -> Result<SessionResponse, CloudError> {
        guard !policy.updateRequired else {
            return .failure(.invalid("Glide Viewer \(GlideVersion.version) is older than \(orgName)'s minimum (\(policy.minAppVersion ?? "?")). Update it to connect."))
        }
        guard let c = device?.client, c.userToken != nil else { return .failure(.invalid("Sign in to \(orgName) first.")) }
        do { return .success(try await c.createSession(hostId: host.id, viewOnly: viewOnly)) } catch let e as CloudError {
            if e.isUnauthorized { await MainActor.run { self.userCallUnauthorized() } }
            return .failure(e)
        } catch {
            return .failure(.transport("\(error)"))
        }
    }

    var cloudURL: URL? { status?.cloudURL }
    var audit: AuditReporter? { isEnrolled ? device?.audit : nil }
    var client: CloudClient? { device?.client }
}

/// One managed session's way in, for ViewerSession: asks the cloud for the session, waits for the
/// host's approval, opens the relay and hands over the loopback connection once the host joined.
/// The host key the cloud named is pinned for `relay:<session_id>`, in memory only.
final class CloudConnector {
    let host: CloudHost
    let viewOnly: Bool
    private(set) var pin: RelayPin?
    private(set) var permissions: CloudPermissions?
    private(set) var sessionId: String?
    private var bridge: RelayBridge?
    private var attempt = 0

    init(host: CloudHost, viewOnly: Bool) {
        self.host = host
        self.viewOnly = viewOnly
    }

    var hostName: String { pin?.hostName ?? PairedViewer.displayName(host.name) }

    /// Main thread. `status` texts for the window; `completion` once with the connection (already
    /// connected, started on `queue`) or the reason it failed.
    func open(queue: DispatchQueue, status: @escaping (String) -> Void, completion: @escaping (Result<NWConnection, CloudFailure>) -> Void) {
        close(byUser: false)
        attempt += 1
        let mine = attempt
        let name = PairedViewer.displayName(host.name)
        status(host.approval == .required ? "Waiting for \(name) to approve…" : "Connecting to \(name) through Glide Cloud…")
        Task {
            let r = await ManagedViewer.shared.createSession(host, viewOnly: viewOnly)
            await MainActor.run {
                guard mine == self.attempt else { return }
                switch r {
                case let .failure(e): completion(.failure(CloudFailure(e.sessionText)))
                case let .success(s): self.started(s, queue: queue, status: status, completion: completion)
                }
            }
        }
    }

    private func started(_ s: SessionResponse, queue: DispatchQueue, status: @escaping (String) -> Void, completion: @escaping (Result<NWConnection, CloudFailure>) -> Void) {
        guard let pin = RelayPin(s), s.host.id == host.id, let cloud = ManagedViewer.shared.cloudURL,
              let url = RelayEndpoint.url(s.relayURL, ticket: s.ticket, sessionId: s.sessionId, cloudURL: cloud) else {
            completion(.failure(CloudFailure("Glide Cloud sent an invalid session (host key or relay address).")))
            return
        }
        self.pin = pin
        // Never more than was asked: a view-only request stays view only whatever comes back.
        var p = s.permissions
        if viewOnly { p.control = false; p.clipboard = .off; p.files = .off }
        permissions = p
        sessionId = s.sessionId
        print("cloud: session \(s.sessionId) with \(pin.hostName) (\(GlideHandshake.fingerprint(pin.hostKey))): \(p.summary)")
        let b = RelayBridge(socket: URLSessionWebSocket(request: URLRequest(url: url, timeoutInterval: 30)))
        bridge = b
        var delivered = false
        b.onStatus = { st in
            DispatchQueue.main.async {
                switch st {
                case .connecting: status("Connecting to \(pin.hostName) through the relay…")
                case .waiting: status("Waiting for \(pin.hostName) to join…")
                case .joined: status("Starting a secure session with \(pin.hostName)…")
                }
            }
        }
        b.onClosed = { why in
            DispatchQueue.main.async {
                if !delivered { delivered = true; completion(.failure(CloudFailure("The relay closed: \(why)."))) }
            }
        }
        b.start(sessionQueue: queue) { conn in
            DispatchQueue.main.async {
                guard !delivered else { conn.cancel(); return }
                delivered = true
                completion(.success(conn))
            }
        }
    }

    /// Ends the managed session (window closed, Disconnect, reconnect). `byUser`: the person at
    /// this Mac ended it (audit `session.local_end`, `POST /v1/sessions/{id}/end`).
    func close(byUser: Bool) {
        attempt += 1
        bridge?.close(byUser ? "ended by the viewer" : "closed")
        bridge = nil
        if let sid = sessionId {
            if byUser {
                ManagedViewer.shared.audit?.localEnd(sessionId: sid, byHostUser: false)
                ManagedViewer.shared.audit?.flush()
            }
            if let c = ManagedViewer.shared.client { Task { try? await c.endSession(sid, as: .user) } }
        }
        sessionId = nil
        pin = nil
    }
}

/// "Sign in to your organization": shows the code, opens the verification page in the default
/// browser and waits for the approval (ENTERPRISE.md §5.2).
final class SignInController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let title = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open Browser Again", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var verificationURL: URL?
    private var cancelled = false
    private var finished = false
    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sign In"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        title.font = .boldSystemFont(ofSize: 15)
        info.textColor = .secondaryLabelColor
        code.font = .monospacedSystemFont(ofSize: 30, weight: .semibold)
        code.isSelectable = true
        code.alignment = .center
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        openButton.target = self; openButton.action = #selector(openBrowser)
        openButton.isEnabled = false
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), openButton, cancelButton])
        let stack = NSStackView(views: [title, info, code, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 400),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            code.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
    }

    func start() {
        let mv = ManagedViewer.shared
        title.stringValue = "Sign in to \(mv.orgName)"
        info.stringValue = "Glide opens your organization's sign-in page in your browser. After you sign in, check that the page shows this code, then approve."
        code.stringValue = "…"
        statusLabel.stringValue = "Starting…"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mv.signIn(progress: { [weak self] s in
            guard let self, !self.cancelled else { return }
            self.code.stringValue = s.userCode
            self.verificationURL = Self.safeURL(s.verificationURIComplete) ?? Self.safeURL(s.verificationURI)
            self.openButton.isEnabled = self.verificationURL != nil
            self.statusLabel.stringValue = "Waiting for you to approve in the browser… (the code expires in \(max(1, s.expiresIn / 60)) min)"
            self.openBrowser()
        }, isCancelled: { [weak self] in self?.cancelled ?? true }, done: { [weak self] err in
            guard let self, !self.cancelled else { return }
            self.finished = true
            if let err {
                self.statusLabel.stringValue = err
                self.statusLabel.textColor = .systemRed
                self.cancelButton.title = "Close"
                self.openButton.isEnabled = false
            } else {
                self.window.close()
            }
        })
    }

    /// Only https pages on the cloud's own host are opened (http for a loopback dev cloud).
    static func safeURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let cloud = ManagedViewer.shared.cloudURL, u.host?.lowercased() == cloud.host?.lowercased() else { return nil }
        if u.scheme?.lowercased() == "https" || (u.scheme?.lowercased() == "http" && cloud.scheme?.lowercased() == "http") { return u }
        return nil
    }

    @objc private func openBrowser() {
        if let u = verificationURL { NSWorkspace.shared.open(u) }
    }

    @objc private func cancel() { window.close() }

    func windowWillClose(_ notification: Notification) {
        if !finished { cancelled = true }
        onClose?()
    }
}

/// Why a managed session couldn't start, in words for the window.
struct CloudFailure: Error {
    let text: String
    init(_ text: String) { self.text = text }
}
