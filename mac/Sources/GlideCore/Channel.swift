import CryptoKit
import Foundation
import Network

/// Encrypted, framed message channel over a TCP NWConnection.
/// All callbacks are delivered on `queue`. `send` may be called from any thread.
public final class SecureChannel: @unchecked Sendable {
    public enum Role { case host, client }

    public let connection: NWConnection
    public let queue: DispatchQueue
    private var sendCipher: RecordCipher?
    private var recvCipher: RecordCipher?
    private let sendLock = NSLock()
    private var inFlight = 0
    private let inFlightLock = NSLock()
    private var closed = false

    public var onMessage: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    /// Bytes handed to the network stack but not yet confirmed processed.
    public var bytesInFlight: Int { inFlightLock.lock(); defer { inFlightLock.unlock() }; return inFlight }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let p = NWParameters(tls: nil, tcp: tcp)
        p.serviceClass = .interactiveVideo
        return p
    }

    // MARK: Raw I/O

    private func readExactly(_ n: Int, _ done: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
            if let error { done(.failure(error)); return }
            guard let data, data.count == n else { done(.failure(isComplete ? WireError.closed : WireError.truncated)); return }
            done(.success(data))
        }
    }

    private func writeRaw(_ d: Data, _ done: ((Error?) -> Void)? = nil) {
        inFlightLock.lock(); inFlight += d.count; inFlightLock.unlock()
        connection.send(content: d, completion: .contentProcessed { [weak self] err in
            if let self { self.inFlightLock.lock(); self.inFlight -= d.count; self.inFlightLock.unlock() }
            done?(err)
        })
    }

    // MARK: Handshake (docs/PROTOCOL.md §1)

    /// Why a host-side handshake didn't complete.
    public enum HandshakeFailure: Error, CustomStringConvertible {
        /// A Glide v1 (password) viewer; it was sent the v1-style "unsupported version 2" reply.
        case v1Viewer
        /// Answered with HostPreamble status != 0 (rate limited, paused, version).
        case refused(UInt16)
        public var description: String {
            switch self {
            case .v1Viewer: return "Glide v1 viewer (password protocol) — it was told to update"
            case .refused(let s): return "refused with status \(s)"
            }
        }
    }

    /// Result of the host side of the handshake: who the viewer is (authenticated by Noise XX).
    public struct HostAccepted {
        public let viewerKey: Data
        public let info: GlideHandshake.ViewerInfo
        /// n_h, to reveal if this connection pairs.
        public let hostNonce: Data
        public let handshakeHash: Data
    }

    private func readFrame(_ done: @escaping (Result<Data, Error>) -> Void) {
        readExactly(2) { [self] res in
            switch res {
            case .failure(let e): done(.failure(e))
            case .success(let h):
                let n = Int(h[h.startIndex]) | Int(h[h.startIndex + 1]) << 8
                guard n <= GlideHandshake.maxMessage else { done(.failure(GlideHandshake.HandshakeError.malformed("handshake message too large"))); return }
                if n == 0 { done(.success(Data())); return }
                readExactly(n, done)
            }
        }
    }

    /// Host (responder) side. `admission` runs after the ClientPreamble + msg1 arrived and before
    /// any DH: it returns the HostPreamble status (0 = continue; e.g. 3 = rate limited) and the
    /// msg2 flags (pairing window open).
    public func acceptHandshake(identity: Curve25519.KeyAgreement.PrivateKey,
                                admission: @escaping () -> (status: UInt16, flags: UInt8),
                                completion: @escaping (Result<HostAccepted, Error>) -> Void) {
        readExactly(4) { [self] res in
            guard case .success(let magic) = res else { if case .failure(let e) = res { completion(.failure(e)) }; return }
            if magic == GlideHandshake.magicV1 {
                // v1 viewer: let it finish its 54-byte ClientHandshake, answer with the v1 layout
                // carrying version 2 (it reports "unsupported protocol version 2"), then give up.
                readExactly(GlideHandshake.v1ClientSize - 4) { [self] _ in
                    writeRaw(GlideHandshake.v1Rejection()) { _ in completion(.failure(HandshakeFailure.v1Viewer)) }
                }
                return
            }
            guard magic == GlideHandshake.magic else { completion(.failure(GlideHandshake.HandshakeError.badMagic(v1: false))); return }
            readExactly(GlideHandshake.clientPreambleSize - 4) { [self] res in
                guard case .success(let rest) = res else { if case .failure(let e) = res { completion(.failure(e)) }; return }
                let preamble = magic + rest
                readFrame { [self] res in
                    guard case .success(let msg1) = res else { if case .failure(let e) = res { completion(.failure(e)) }; return }
                    let (status, flags) = admission()
                    if status != GlideHandshake.statusOK {
                        writeRaw(GlideHandshake.hostPreamble(status: status)) { _ in completion(.failure(HandshakeFailure.refused(status))) }
                        return
                    }
                    let host: GlideHandshake.Host
                    do {
                        host = try GlideHandshake.Host(identity: identity, preamble: preamble, msg1: msg1)
                    } catch GlideHandshake.HandshakeError.status(_, let st) {
                        writeRaw(GlideHandshake.hostPreamble(status: st)) { _ in completion(.failure(HandshakeFailure.refused(st))) }
                        return
                    } catch { completion(.failure(error)); return }
                    let flight: Data
                    do { flight = try host.writeMsg2(flags: flags) } catch { completion(.failure(error)); return }
                    writeRaw(flight)
                    readFrame { [self] res in
                        switch res {
                        case .failure(let e): completion(.failure(e))
                        case .success(let msg3):
                            do {
                                let (key, info) = try host.readMsg3(msg3)
                                let est = host.finish()
                                sendCipher = RecordCipher(key: est.sendKey)
                                recvCipher = RecordCipher(key: est.recvKey)
                                completion(.success(HostAccepted(viewerKey: key, info: info, hostNonce: host.nonce, handshakeHash: est.handshakeHash)))
                            } catch { completion(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    /// Result of the viewer side of the handshake (msg3 already sent).
    public struct ViewerConnected {
        public let hostKey: Data
        public let hostInfo: GlideHandshake.HostInfo
        public let viewerNonce: Data
        public let handshakeHash: Data
        /// msg3 asked to pair: expect PairReveal next.
        public let pairing: Bool
    }

    public enum ViewerFailure: Error, CustomStringConvertible {
        case hostKeyChanged(pinned: Data, presented: Data)
        /// The host closed without answering (a v1 host does that).
        case hostIsV1
        public var description: String {
            switch self {
            case let .hostKeyChanged(p, n): return "host key changed: pinned \(GlideHandshake.fingerprint(p)), presented \(GlideHandshake.fingerprint(n))"
            case .hostIsV1: return "host closed the connection without answering (still Glide v1?)"
            }
        }
    }

    /// Viewer (initiator) side, for glide-probe. Aborts before msg3 if `pinned` doesn't match.
    public func performHandshake(identity: Curve25519.KeyAgreement.PrivateKey, name: String, pinned: Data?, requestPairing: Bool = false,
                                 completion: @escaping (Result<ViewerConnected, Error>) -> Void) {
        let v = GlideHandshake.Viewer(identity: identity, name: name)
        writeRaw(v.firstFlight())
        readExactly(GlideHandshake.hostPreambleSize) { [self] res in
            guard case .success(let pre) = res else { completion(.failure(ViewerFailure.hostIsV1)); return }
            let ver: UInt16
            do { ver = try GlideHandshake.parseHostPreamble(pre) } catch { completion(.failure(error)); return }
            readFrame { [self] res in
                switch res {
                case .failure(let e): completion(.failure(e))
                case .success(let msg2):
                    do {
                        let (key, info) = try v.readMsg2(msg2, preambleVersion: ver)
                        if let pinned, pinned != key { completion(.failure(ViewerFailure.hostKeyChanged(pinned: pinned, presented: key))); return }
                        let pairing = pinned == nil || requestPairing
                        writeRaw(v.writeMsg3(flags: pairing ? GlideHandshake.viewerFlagPairRequest : 0))
                        let est = v.finish()
                        sendCipher = RecordCipher(key: est.sendKey)
                        recvCipher = RecordCipher(key: est.recvKey)
                        completion(.success(ViewerConnected(hostKey: key, hostInfo: info, viewerNonce: v.nonce, handshakeHash: est.handshakeHash, pairing: pairing)))
                    } catch { completion(.failure(error)) }
                }
            }
        }
    }

    // MARK: Records

    /// Encrypts and sends one message. Thread-safe; ordering is preserved.
    public func send(_ plaintext: Data, completion: ((Error?) -> Void)? = nil) {
        sendLock.lock()
        guard let c = sendCipher, !closed else { sendLock.unlock(); completion?(WireError.closed); return }
        let rec = c.seal(plaintext)
        // connection.send preserves call order; keep it under the lock so counter order == wire order.
        writeRaw(rec, completion)
        sendLock.unlock()
    }

    /// Starts the receive loop. Each decrypted plaintext is delivered to `onMessage`.
    public func startReceiving() { readRecord() }

    private func readRecord() {
        readExactly(4) { [self] res in
            guard case .success(let hdr) = res else { if case .failure(let e) = res { close(e) }; return }
            var r = ByteReader(hdr)
            let len = Int((try? r.u32()) ?? 0)
            guard len >= 17, len <= RecordCipher.maxRecord else { close(WireError.recordTooLarge(len)); return }
            readExactly(len) { [self] res in
                switch res {
                case .failure(let e): close(e)
                case .success(let body):
                    do {
                        guard let rc = recvCipher else { throw WireError.closed }
                        let pt = try rc.open(body)
                        onMessage?(pt)
                        if !closed { readRecord() }
                    } catch { close(error) }
                }
            }
        }
    }

    public func close(_ error: Error? = nil) {
        sendLock.lock()
        let was = closed
        closed = true
        sendLock.unlock()
        guard !was else { return }
        connection.cancel()
        onClose?(error)
    }
}
