import CryptoKit
import Foundation
import GlideCore
import Network

/// `glide-selftest --file-host PORT [--key-file F] [--recv DIR] [--send PATH...] [--pull PATH...] [--seconds N]`
///
/// A minimal host for end-to-end tests of file transfer against the real viewer, using the real
/// GlideCore pieces (SecureChannel, FileTransferEngine with the bytesInFlight chunk gate) but no
/// capture: it answers ClientHello with a ServerHello and FileCaps, Ping with Pong, and nothing
/// else (the viewer shows a black canvas). Listens on loopback only (use an ssh -R tunnel).
/// Files from the viewer go to --recv (quarantined); --send pushes items after connect; --pull
/// answers the viewer's Ctrl+Alt+Shift+V. Exits when the viewer disconnects or after --seconds.
/// Security v2: a test host with its own key (--key-file, created if missing) that trusts every
/// viewer: a paired viewer goes straight in, an unpaired one gets an automatically confirmed
/// pairing (the code is printed; the viewer still has to confirm it).
func runFileHost(_ argv: [String]) -> Never {
    var args = argv
    func take(_ f: String) -> String? {
        guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
    }
    func takeList(_ f: String) -> [URL] {
        guard let i = args.firstIndex(of: f) else { return [] }
        var out: [URL] = []
        var j = i + 1
        while j < args.count, !args[j].hasPrefix("--") { out.append(URL(fileURLWithPath: args[j])); j += 1 }
        args.removeSubrange(i..<j)
        return out
    }
    guard let first = args.first, let port = UInt16(first) else { print("usage: glide-selftest --file-host PORT [--key-file F] [--recv DIR] [--send PATH...] [--pull PATH...]"); exit(2) }
    args.removeFirst()
    let keyFile = take("--key-file") ?? FileManager.default.temporaryDirectory.appendingPathComponent("glide-file-host.key").path
    let identity: Curve25519.KeyAgreement.PrivateKey
    if let h = try? String(contentsOfFile: keyFile, encoding: .utf8), let raw = Data(hex: h.trimmingCharacters(in: .whitespacesAndNewlines)),
       let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { identity = k }
    else {
        identity = Curve25519.KeyAgreement.PrivateKey()
        FileManager.default.createFile(atPath: keyFile, contents: Data(identity.rawRepresentation.hex.utf8), attributes: [.posixPermissions: 0o600])
    }
    let recv = URL(fileURLWithPath: take("--recv") ?? FileManager.default.temporaryDirectory.appendingPathComponent("glide-file-host").path)
    let seconds = Double(take("--seconds") ?? "120") ?? 120
    let sendItems = takeList("--send"), pullItems = takeList("--pull")
    let t0 = Date()
    func say(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s); fflush(stdout) }

    let params = SecureChannel.tcpParameters()
    params.requiredInterfaceType = .loopback
    let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    var active: (SecureChannel, FileTransferEngine)?
    listener.newConnectionHandler = { conn in
        guard active == nil else { conn.cancel(); return }
        let ch = SecureChannel(connection: conn, queue: DispatchQueue(label: "file-host.session"))
        let engine = FileTransferEngine(config: .init(downloadDir: recv, hostRole: true))
        active = (ch, engine)
        engine.send = { [weak engine] m, bulk in ch.send(HostMessage.file(m).encoded, completion: bulk ? { _ in engine?.kick() } : nil) }
        engine.canSendBulk = { ch.bytesInFlight < 256 * 1024 }  // same gate as glide-host's SessionFiles
        engine.peerLimits = FileLimits(maxTotalBytes: .max, maxFiles: .max)
        engine.onEvent = { e in
            switch e {
            case let .received(n, bytes, dir, items):
                say("files: RECEIVED \(n) files, \(bytes) bytes into \(dir.path): \(items.map(\.lastPathComponent))")
                if let en = FileManager.default.enumerator(atPath: dir.path) {
                    for case let rel as String in en {
                        let p = dir.appendingPathComponent(rel).path
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                        say("  \(isDir.boolValue ? "DIR " : "FILE") \(rel) quarantine=\(Quarantine.read(p) ?? "MISSING")")
                    }
                }
            default: say("files: \(e)")
            }
        }
        var authed = false
        var pairing = false
        var minOwd = Int64.max
        ch.onMessage = { d in
            guard let m = try? ClientMessage.decode(d) else { say("bad message \(d.prefix(1).hex)"); return }
            if !authed {
                if pairing, case let .pairConfirm(ok) = m {
                    pairing = false
                    say("pairing: viewer \(ok ? "confirmed" : "declined")")
                    if ok { ch.send(HostMessage.authResult(.ok).encoded) } else { ch.close() }
                    return
                }
                guard !pairing, case let .hello(_, caps, _, _, _, _, name) = m else { ch.close(); return }
                authed = true
                say("viewer '\(name)' authenticated, caps \(String(caps.rawValue, radix: 16)), files \(caps.contains(.files))")
                ch.send(HostMessage.serverHello(version: GlideHandshake.version, hostName: "glide-selftest file host",
                                                config: VideoConfig(width: 1280, height: 720, codec: .hevc, chroma: .yuv420, scale: 1)).encoded)
                guard caps.contains(.files) else { return }
                ch.send(HostMessage.file(.caps(flags: 3, maxTotalBytes: 8 << 30, maxFiles: 10000)).encoded)
                if !sendItems.isEmpty {
                    ch.queue.asyncAfter(deadline: .now() + 1) { say("files: sending \(sendItems.map(\.lastPathComponent))"); engine.sendItems(sendItems) }
                }
                return
            }
            switch m {
            case let .ping(t):
                ch.send(HostMessage.pong(clientTimeUs: t, hostTimeUs: hostTimeMicros()).encoded)
                // One-way delay up to a constant clock offset: the excess over the minimum is
                // queueing, e.g. behind file chunks on the viewer's uplink.
                let owd = Int64(bitPattern: hostTimeMicros() &- t)
                minOwd = min(minOwd, owd)
                say(String(format: "ping queueing +%.2f ms (%@)", Double(owd - minOwd) / 1000, engine.progress.contains { $0.incoming } ? "during upload" : "idle"))
            case .file(.pull):
                if pullItems.isEmpty {
                    say("files: pull -> nothing"); engine.send(.pullResult(status: FileStatus.nothing, detail: "No files on the Mac clipboard"), false)
                } else {
                    say("files: pull -> \(pullItems.map(\.lastPathComponent))")
                    engine.send(.pullResult(status: FileStatus.ok, detail: ""), false)
                    engine.sendItems(pullItems)
                }
            case let .file(fm):
                if case let .offer(id, total, files) = fm { say("files: <- offer \(String(id, radix: 16)): \(files.count) files, \(total) bytes: \(files.prefix(6).map(\.path))") }
                engine.handle(fm)
            default: break
            }
        }
        ch.onClose = { err in
            say("connection closed\(err.map { ": \($0)" } ?? "")")
            engine.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
        conn.stateUpdateHandler = { st in
            if case .ready = st {
                ch.acceptHandshake(identity: identity, admission: { (GlideHandshake.statusOK, GlideHandshake.hostFlagPairingOpen) }) { res in
                    guard case let .success(acc) = res else {
                        if case let .failure(e) = res { say("handshake failed: \(e)") }
                        ch.close(); return
                    }
                    say("viewer key \(GlideHandshake.fingerprint(acc.viewerKey))\(acc.info.pairRequest ? " asks to pair" : "")")
                    ch.startReceiving()
                    if acc.info.pairRequest {
                        pairing = true
                        let code = GlideHandshake.sasCode(handshakeHash: acc.handshakeHash, viewerNonce: acc.info.nonce, hostNonce: acc.hostNonce)
                        say("pairing: code \(GlideHandshake.sasText(code)) (auto-confirmed on this test host)")
                        ch.send(HostMessage.pairReveal(nonce: acc.hostNonce).encoded)
                    }
                }
            }
        }
        conn.start(queue: ch.queue)
    }
    listener.stateUpdateHandler = { st in if case .ready = st { say("file host listening on 127.0.0.1:\(port) (key \(GlideHandshake.fingerprint(identity.publicKey.rawRepresentation))), saving to \(recv.path)") } }
    listener.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { say("time limit"); exit(0) }
    dispatchMain()
}
