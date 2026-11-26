import Foundation

public enum WSMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// A WebSocket as the hub and relay clients use it. `URLSessionWebSocket` is the real one; the
/// self-test uses an in-memory fake. Callbacks may arrive on any queue.
public protocol CloudWebSocket: AnyObject {
    /// Opens the connection (the upgrade happens in the background; failures surface in `receive`).
    func start()
    func send(_ m: WSMessage, completion: @escaping (Error?) -> Void)
    /// Delivers the next message, or an error once the socket closed or failed.
    func receive(_ completion: @escaping (Result<WSMessage, Error>) -> Void)
    func close(code: Int)
    /// HTTP status of a refused upgrade (401 = not enrolled, 409 = already connected), if known.
    var upgradeStatus: Int? { get }
    /// The close code the peer sent, if any.
    var closeCode: Int? { get }
}

/// Makes sockets for a request (the hub and relay clients get one per connection attempt).
public typealias CloudWebSocketFactory = (URLRequest) -> CloudWebSocket

/// `URLSessionWebSocketTask` on the cloud transport's session (system proxy and trust store, no
/// redirects). Messages are capped at 1 MiB + 1 KiB (relay frames are ≤ 1 MiB, §6.5).
public final class URLSessionWebSocket: CloudWebSocket, @unchecked Sendable {
    public static let maxMessage = (1 << 20) + 1024
    private let task: URLSessionWebSocketTask

    public init(request: URLRequest, session: URLSession = URLSessionTransport.shared.session) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maxMessage
    }

    public static let factory: CloudWebSocketFactory = { URLSessionWebSocket(request: $0) }

    public func start() { task.resume() }

    public func send(_ m: WSMessage, completion: @escaping (Error?) -> Void) {
        switch m {
        case let .text(s): task.send(.string(s), completionHandler: completion)
        case let .binary(d): task.send(.data(d), completionHandler: completion)
        }
    }

    public func receive(_ completion: @escaping (Result<WSMessage, Error>) -> Void) {
        task.receive { r in
            switch r {
            case let .success(.string(s)): completion(.success(.text(s)))
            case let .success(.data(d)): completion(.success(.binary(d)))
            case .success: completion(.failure(CloudError.transport("unknown WebSocket message")))
            case let .failure(e): completion(.failure(e))
            }
        }
    }

    public func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    public var upgradeStatus: Int? {
        guard let h = task.response as? HTTPURLResponse, h.statusCode != 101 else { return nil }
        return h.statusCode
    }

    public var closeCode: Int? {
        let c = task.closeCode.rawValue
        return c == 0 ? nil : c
    }
}
