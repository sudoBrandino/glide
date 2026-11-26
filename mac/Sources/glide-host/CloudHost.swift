import AppKit
import CryptoKit
import Foundation
import GlideCore
import Network

/// Managed mode on the host (docs/ENTERPRISE.md): the Glide Cloud enrollment (CloudDevice), the
/// org policy's effect on the server (LAN mode, pairing), session offers with the approval
/// prompt, and each accepted session's relay bridge, grant and hub `session_state` reports.
/// Main-queue owned; the cloud's callbacks hop here.
final class ManagedHost: @unchecked Sendable {
    static let shared = ManagedHost()
    let grants = GrantStore()
    private(set) var device: CloudDevice?
    private var config = ManagedConfig()
    private weak var server: Server?
    private var prompt: ApprovalPrompt?
    private var lastPolicy: ManagedPolicy?

    /// One accepted session, from `session_answer` until it ends.
    private final class Relay {
        let offer: SessionOffer
        let bridge: RelayBridge
        var session: Session?
        var connected = false
        var endedByHostUser = false
        var finished = false
        init(offer: SessionOffer, bridge: RelayBridge) { self.offer = offer; self.bridge = bridge }
    }
    private var relays: [String: Relay] = [:]

    var isManaged: Bool { device?.status.isManaged ?? false }

    /// The policy now (cached org settings + DisableLANMode before the cloud answers).
    var policy: ManagedPolicy {
        device?.status.policy ?? ManagedPolicy(settings: nil, disableLANMode: config.disableLANMode, appVersion: GlideVersion.version)
    }

    var audit: AuditReporter? { device?.status.isEnrolled == true ? device?.audit : nil }

    /// Reads the managed configuration and the stored enrollment (its cached settings apply at
    /// once). No network yet.
    func prepare(identity: Curve25519.KeyAgreement.PrivateKey) {
        config = ManagedConfig.read()
        for p in config.problems { log("cloud: managed settings: \(p)") }
        if config.disableLANMode { log("cloud: DisableLANMode is set: LAN connections are off on this Mac") }
        guard config.cloudURL != nil else {
            publish(nil)
            return
        }
        let d = CloudDevice(kind: .host, publicKey: identity.publicKey.rawRepresentation,
                            store: EnrollmentStore.file(for: .host, in: HostConfig.dir), config: config)
        d.log = { log($0) }
        d.onStatus = { [weak self] st in DispatchQueue.main.async { self?.publish(st) } }
        d.onHubEvent = { [weak self] ev in DispatchQueue.main.async { self?.hubEvent(ev) } }
        d.onRevoked = { [weak self] _ in DispatchQueue.main.async { self?.revoked() } }
        device = d
        log("cloud: managed by \(config.cloudURL!.absoluteString)\(d.status.isEnrolled ? " (enrolled as \(d.status.deviceId ?? "?"))" : "")")
        publish(d.status)
    }

    /// Connects to Glide Cloud (enrolling first if needed).
    func start(server: Server) {
        self.server = server
        device?.start()
    }

    // MARK: Status and policy

    private func publish(_ st: CloudDevice.Status?) {
        let p = st?.policy ?? policy
        let managed: HostStatus.Managed? = st.map { s in
            var m = HostStatus.Managed(summary: s.summary)
            m.orgName = s.orgName
            m.deviceName = s.deviceName
            m.deviceId = s.deviceId
            m.cloudURL = s.cloudURL?.absoluteString
            m.enrolledAt = s.enrolledAt
            m.enrolled = s.isEnrolled
            if case let .enrolled(c) = s.state { m.connected = c }
            m.lanAllowed = p.lanAllowed
            m.lanOffReason = ManagedPolicy.lanOffReason(settings: s.settings, disableLANMode: s.disableLANMode, orgName: s.orgName)
            m.pairingAllowed = p.localPairingAllowed
            m.updateRequired = p.updateRequired
            m.minAppVersion = p.minAppVersion
            m.problems = s.configProblems
            return m
        } ?? (config.disableLANMode ? {
            var m = HostStatus.Managed(summary: "LAN mode turned off by this Mac's managed settings")
            m.lanAllowed = false
            m.lanOffReason = ManagedPolicy.lanOffReason(settings: nil, disableLANMode: true, orgName: nil)
            m.pairingAllowed = false
            return m
        }() : nil)
        HostStatus.shared.update { $0.managed = managed }
        guard p != lastPolicy else { return }
        lastPolicy = p
        server?.setLANAllowed(p.lanAllowed)
        if !p.localPairingAllowed, PairingController.shared.window.isOpen() {
            PairingController.shared.cancelWindow(source: "pairing turned off by the organization")
        }
        if p.updateRequired { log("cloud: this app (\(GlideVersion.version)) is older than the org's minimum \(p.minAppVersion ?? "?"): managed sessions are refused until it is updated") }
    }

    /// Applies the launch policy to the server before it starts listening.
    func applyInitialPolicy(to server: Server) {
        self.server = server
        lastPolicy = policy
        server.setLANAllowed(policy.lanAllowed)
    }

    // MARK: Hub

    private func hubEvent(_ ev: HubEvent) {
        switch ev {
        case let .offer(o): handleOffer(o)
        case let .invalidOffer(sid, why):
            // A security field is missing (§6.7): refuse without prompting.
            log("cloud: session offer \(sid) is missing a required field (\(why)); declining (policy)")
            device?.send(.sessionAnswer(sessionId: sid, accept: false, reason: "policy"))
        case let .cancel(id, reason):
            log("cloud: session \(id) cancelled (\(reason.isEmpty ? "no reason" : reason))")
            grants.revoke(id)
            if prompt?.offer.sessionId == id { prompt?.dismiss(); prompt = nil; HostStatus.shared.update { $0.pendingApproval = nil } }
            if let r = relays[id] { r.session?.end(); finish(id, detail: "cancelled: \(reason)") }
        default: break
        }
    }

    /// Any session (LAN or managed) runs, or another offer is being prompted (§6.7: `busy`
    /// without prompting).
    private var isBusy: Bool {
        guard let server else { return true }
        return server.current != nil || prompt != nil || relays.values.contains { !$0.finished }
    }

    private func handleOffer(_ o: SessionOffer) {
        guard let d = device, let url = d.status.cloudURL, let server else { return }
        let decision = OfferDecision.decide(o, cloudURL: url, busy: isBusy, paused: server.isPaused, updateRequired: policy.updateRequired)
        log("cloud: session offer \(o.sessionId) from \(o.user.label) on “\(CloudText.name(o.viewer.name, fallback: "unnamed viewer"))” (\(o.permissions.summary), approval \(o.approval.rawValue)) -> \(decision)")
        switch decision {
        case .accept: accept(o)
        case let .decline(reason): answer(o, accept: false, reason: reason)
        case .prompt:
            guard prompt == nil else { answer(o, accept: false, reason: "busy"); return }
            let p = ApprovalPrompt(offer: o, orgName: d.status.orgName)
            prompt = p
            HostStatus.shared.update { $0.pendingApproval = o.user.label }
            p.show { [weak self] accepted, reason in
                guard let self, self.prompt === p else { return }
                self.prompt = nil
                HostStatus.shared.update { $0.pendingApproval = nil }
                log("cloud: session \(o.sessionId) \(accepted ? "accepted" : "declined") by the person at this Mac\(reason == "timeout" ? " (no answer in 50 s)" : "")")
                // The grant's lifetime starts now, at acceptance (accept() → SessionGrant).
                switch OfferDecision.afterPrompt(accepted: accepted, reason: reason, expiresAt: o.expiresAt, busy: self.isBusy) {
                case .accept: self.accept(o)
                case let .decline(why): self.answer(o, accept: false, reason: why)
                case .prompt: self.answer(o, accept: false, reason: "declined")
                }
            }
        }
    }

    private func answer(_ o: SessionOffer, accept: Bool, reason: String?) {
        device?.send(.sessionAnswer(sessionId: o.sessionId, accept: accept, reason: reason))
    }

    /// Answers yes, keeps the grant in memory, then opens the relay (§5.3: only after accepting).
    private func accept(_ o: SessionOffer) {
        guard let d = device, let cloud = d.status.cloudURL, let server,
              let g = SessionGrant(offer: o),
              let url = RelayEndpoint.url(o.relayURL, ticket: o.ticket, sessionId: o.sessionId, cloudURL: cloud) else {
            answer(o, accept: false, reason: "policy")
            return
        }
        grants.add(g)
        answer(o, accept: true, reason: nil)
        let bridge = RelayBridge(socket: URLSessionWebSocket(request: URLRequest(url: url, timeoutInterval: 30)))
        let r = Relay(offer: o, bridge: bridge)
        relays[o.sessionId] = r
        let sid = o.sessionId
        bridge.onStatus = { st in if st == .waiting { log("cloud: session \(sid): waiting for the viewer on the relay") } }
        bridge.onClosed = { [weak self, weak bridge] why in
            let failed = bridge?.failed ?? false  // on the bridge queue, set before onClosed
            DispatchQueue.main.async { self?.relayClosed(sid, why, failed: failed) }
        }
        let queue = DispatchQueue(label: "glide.session.relay", qos: .userInteractive)
        let audit = self.audit
        bridge.start(sessionQueue: queue) { [weak self, weak server] conn in
            guard let server else { conn.cancel(); return }
            server.adoptRelay(conn, queue: queue, sessionId: sid, grants: self?.grants ?? GrantStore(), audit: audit,
                              onAuthenticated: { s in DispatchQueue.main.async { self?.connected(sid, s) } },
                              onEnd: { s in DispatchQueue.main.async { self?.sessionEnded(sid, s) } })
        }
        // The viewer must show up while the grant lives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 130) { [weak self] in
            guard let self, let r = self.relays[sid], !r.connected, !r.finished else { return }
            log("cloud: session \(sid): the viewer never completed the handshake; closing")
            self.audit?.error(code: "handshake_timeout", message: "the viewer did not complete the handshake in time", sessionId: sid)
            r.bridge.close("no handshake")
            self.finish(sid, detail: "the viewer did not connect")
        }
    }

    private func connected(_ sid: String, _ s: Session) {
        guard let r = relays[sid], !r.finished else { s.end(); return }
        r.session = s
        r.connected = true
        device?.send(.sessionState(sessionId: sid, state: "connected", detail: nil))
        log("cloud: session \(sid): \(r.offer.user.label) is connected")
    }

    private func sessionEnded(_ sid: String, _ s: Session) {
        guard let r = relays[sid] else { return }
        if r.session == nil || r.session === s {
            r.bridge.close("session ended")
            finish(sid, detail: r.endedByHostUser ? "ended by the host user" : nil)
        }
    }

    private func relayClosed(_ sid: String, _ why: String, failed: Bool) {
        guard let r = relays[sid] else { return }
        log("cloud: session \(sid): relay closed (\(why))")
        if failed { audit?.error(code: "relay_failed", message: why, sessionId: sid) }
        r.session?.end()
        finish(sid, detail: why)
    }

    /// Reports `ended` once and forgets the session.
    private func finish(_ sid: String, detail: String?) {
        grants.revoke(sid)
        guard let r = relays[sid], !r.finished else { return }
        r.finished = true
        relays[sid] = nil
        device?.send(.sessionState(sessionId: sid, state: "ended", detail: detail))
    }

    /// Menu bar → End Session: the person at this Mac ends the managed session.
    func endByHostUser(_ s: Session) {
        guard let sid = s.relaySessionId else { s.end(); return }
        relays[sid]?.endedByHostUser = true
        audit?.localEnd(sessionId: sid, byHostUser: true)
        audit?.flush()
        if let c = device?.client { Task { try? await c.endSession(sid, as: .device) } }
        log("cloud: session \(sid) ended by the person at this Mac")
        s.end()
    }

    private func revoked() {
        log("cloud: removed from the organization; ending managed sessions")
        grants.revokeAll()
        prompt?.dismiss(); prompt = nil
        HostStatus.shared.update { $0.pendingApproval = nil }
        for (sid, r) in relays {
            r.bridge.close("revoked")
            r.session?.end()
            relays[sid] = nil
        }
        for s in server?.sessions.all ?? [] where s.relaySessionId != nil { s.end() }
    }
}

/// The approval prompt for `approval: "required"` (ENTERPRISE.md §6.4): it names the user and
/// email, Decline is the default button, Accept is enabled after 1 s, and it declines by itself
/// after 50 s. Like the pairing alert it floats above other windows without taking focus, and
/// Return and Escape mean Decline.
final class ApprovalPrompt: NSObject {
    static let declineIndex = 0, acceptIndex = 1
    let offer: SessionOffer
    private let orgName: String?
    private var alert: NSAlert?
    private var done: ((Bool, String) -> Void)?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var deadline = Date()
    private let countdown = NSTextField(labelWithString: "")

    init(offer: SessionOffer, orgName: String?) {
        self.offer = offer
        self.orgName = orgName
    }

    /// Builds the alert (also for previews): buttons[declineIndex] = Decline (Return, focus),
    /// buttons[acceptIndex] = Accept (disabled until armed).
    static func makeAlert(offer o: SessionOffer, orgName: String?, countdown: NSTextField) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = ApprovalText.title(o)
        a.informativeText = ApprovalText.body(o, orgName: orgName)
        countdown.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countdown.textColor = .secondaryLabelColor
        countdown.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        a.accessoryView = countdown
        let decline = a.addButton(withTitle: "Decline")
        let accept = a.addButton(withTitle: "Accept")
        decline.keyEquivalent = "\r"
        accept.keyEquivalent = ""
        accept.isEnabled = false
        a.window.initialFirstResponder = decline
        return a
    }

    func show(_ completion: @escaping (_ accepted: Bool, _ reason: String) -> Void) {
        done = completion
        let a = Self.makeAlert(offer: offer, orgName: orgName, countdown: countdown)
        let decline = a.buttons[Self.declineIndex], accept = a.buttons[Self.acceptIndex]
        decline.target = self; decline.action = #selector(declineClicked)
        accept.target = self; accept.action = #selector(acceptClicked)
        a.layout()
        let w = a.window
        w.level = .floating
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        (w as? NSPanel)?.hidesOnDeactivate = false
        w.center()
        w.orderFrontRegardless()  // shown, not focused
        alert = a
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak w] e in
            guard let w, e.window === w, e.keyCode == 53 /* Escape */ else { return e }
            self?.finish(false, "declined")
            return nil
        }
        deadline = Date().addingTimeInterval(OfferDecision.promptTimeout)
        updateCountdown()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + OfferDecision.acceptDelay) { [weak self, weak a] in
            guard let self, let a, self.alert === a else { return }
            a.buttons[Self.acceptIndex].isEnabled = true
        }
        NSSound.beep()
    }

    private func tick() {
        if Date() >= deadline { finish(false, "timeout") } else { updateCountdown() }
    }

    private func updateCountdown() {
        countdown.stringValue = "Declines automatically in \(max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))) s"
    }

    /// The offer was cancelled (viewer gave up, admin ended it): close without answering.
    func dismiss() {
        done = nil
        close()
    }

    private func finish(_ accepted: Bool, _ reason: String) {
        let d = done
        done = nil
        close()
        d?(accepted, reason)
    }

    private func close() {
        timer?.invalidate(); timer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        alert?.window.orderOut(nil)
        alert = nil
    }

    @objc private func acceptClicked() { finish(true, "") }
    @objc private func declineClicked() { finish(false, "declined") }
}
