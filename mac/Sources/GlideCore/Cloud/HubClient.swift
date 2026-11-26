import Foundation

/// What the hub tells the app (docs/ENTERPRISE.md §6.4).
public enum HubEvent: Equatable, Sendable {
    /// `hello`: connected; the current org settings.
    case connected(deviceId: String, settings: OrgSettings)
    case offer(SessionOffer)
    /// An offer missing a security field (§6.7) whose `session_id` is known: decline with `policy`.
    case invalidOffer(sessionId: String, why: String)
    case cancel(sessionId: String, reason: String)
    case settings(OrgSettings)
    /// A `revoked` frame, or `401` on the upgrade: the device is no longer enrolled. The client has
    /// stopped; the app wipes the enrollment and ends its managed sessions.
    case revoked(reason: String)
    /// The socket closed or failed; the client reconnects after `retryIn` seconds.
    case disconnected(retryIn: TimeInterval, why: String)
}

/// The device's hub connection (`GET /v1/hub`): JSON text frames, `pong` for every `ping`,
/// reconnect with exponential backoff (1 s doubling to 60 s, ±20 % jitter) until stopped or
/// revoked. All state lives on `queue`; `onEvent` is called there.
public final class HubClient: @unchecked Sendable {
    public let queue: DispatchQueue
    public var onEvent: (HubEvent) -> Void = { _ in }
    /// No frame for this long (the hub pings every 30 s): the socket is presumed dead.
    public var staleAfter: TimeInterval = 75

    private let makeRequest: () throws -> URLRequest
    private let factory: CloudWebSocketFactory
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let random: () -> Double
    private var backoff = CloudBackoff()
    private var socket: CloudWebSocket?
    private var connectionId = 0
    private var stopped = true
    private var lastFrame = Date()
    private var staleTimer: DispatchSourceTimer?

    /// `schedule` and `random` are injectable for tests (default: `queue.asyncAfter`, uniform).
    public init(request: @escaping () throws -> URLRequest, factory: @escaping CloudWebSocketFactory = URLSessionWebSocket.factory,
                queue: DispatchQueue = DispatchQueue(label: "glide.cloud.hub"),
                schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil, random: (() -> Double)? = nil) {
        self.makeRequest = request
        self.factory = factory
        self.queue = queue
        self.schedule = schedule ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        self.random = random ?? { Double.random(in: 0..<1) }
    }

    public func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            backoff.reset()
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in stopOnQueue(code: RelayCloseCode.normal) }
    }

    /// Sends a frame on the current connection (dropped while disconnected).
    public func send(_ f: HubClientFrame) {
        queue.async { [self] in
            socket?.send(.text(f.json)) { _ in }
        }
    }

    public var isConnected: Bool { queue.sync { socket != nil && !stopped } }

    private func stopOnQueue(code: Int) {
        stopped = true
        connectionId += 1
        staleTimer?.cancel(); staleTimer = nil
        socket?.close(code: code)
        socket = nil
    }

    private func connect() {
        guard !stopped else { return }
        connectionId += 1
        let id = connectionId
        let req: URLRequest
        do { req = try makeRequest() } catch {
            reconnectLater(id: id, why: "\(error)")
            return
        }
        let s = factory(req)
        socket = s
        lastFrame = Date()
        armStaleTimer(id: id)
        s.start()
        receive(id: id, s)
    }

    private func receive(id: Int, _ s: CloudWebSocket) {
        s.receive { [weak self] r in
            guard let self else { return }
            self.queue.async {
                guard id == self.connectionId, !self.stopped else { return }
                switch r {
                case let .success(m):
                    self.lastFrame = Date()
                    if case let .text(t) = m { self.handle(t, s) }
                    if id == self.connectionId, !self.stopped { self.receive(id: id, s) }
                case let .failure(e):
                    if s.upgradeStatus == 401 {
                        self.stopOnQueue(code: RelayCloseCode.normal)
                        self.onEvent(.revoked(reason: "unauthorized"))
                        return
                    }
                    let why = s.upgradeStatus.map { "HTTP \($0)" } ?? s.closeCode.map { "closed (\($0))" } ?? (e as NSError).localizedDescription
                    self.reconnectLater(id: id, why: why)
                }
            }
        }
    }

    private func handle(_ text: String, _ s: CloudWebSocket) {
        let f: HubServerFrame
        do { f = try HubServerFrame.decode(text) } catch { return }  // malformed: ignored
        switch f {
        case let .hello(deviceId, settings, _):
            backoff.reset()
            onEvent(.connected(deviceId: deviceId, settings: settings))
        case let .sessionOffer(o): onEvent(.offer(o))
        case let .invalidOffer(sid?, why) where CloudID.isValid(sid): onEvent(.invalidOffer(sessionId: sid, why: why))
        case .invalidOffer: break  // nothing to answer
        case let .sessionCancel(id, reason): onEvent(.cancel(sessionId: id, reason: reason))
        case let .settings(st): onEvent(.settings(st))
        case let .revoked(reason):
            stopOnQueue(code: RelayCloseCode.normal)
            onEvent(.revoked(reason: reason))
        case let .ping(t): s.send(.text(HubClientFrame.pong(t: t).json)) { _ in }
        case .unknown: break
        }
    }

    private func reconnectLater(id: Int, why: String) {
        guard id == connectionId, !stopped else { return }
        staleTimer?.cancel(); staleTimer = nil
        socket?.close(code: RelayCloseCode.normal)
        socket = nil
        connectionId += 1  // late callbacks of the dead socket are ignored
        let next = connectionId
        let delay = backoff.next(random: random())
        onEvent(.disconnected(retryIn: delay, why: why))
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, self.connectionId == next, self.socket == nil else { return }
                self.connect()
            }
        }
    }

    private func armStaleTimer(id: Int) {
        staleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self, id == self.connectionId, !self.stopped else { return }
            if Date().timeIntervalSince(self.lastFrame) > self.staleAfter { self.reconnectLater(id: id, why: "no frames for \(Int(self.staleAfter)) s") }
        }
        t.resume()
        staleTimer = t
    }
}
