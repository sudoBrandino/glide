import CryptoKit
import Foundation
import GlideCore
import Network

// Security v2 (docs/PROTOCOL.md §1–2):
// - Noise XX against the official vectors (docs/noise-vectors.json),
// - the Glide handshake + pairing + records against the Python reference transcript
//   (docs/test-vectors.json) and the Rust-generated one (docs/test-vectors-rust.json),
// - the I/O path (SecureChannel) over loopback TCP, incl. v1-viewer and rate-limit answers,
// - pairing window / vote / rate limiter / control socket logic.

private func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: hex)!)
}

private func json(_ path: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
}

func noiseVectorTests(_ path: String) throws {
    print("noise vectors (\(URL(fileURLWithPath: path).lastPathComponent)):")
    let doc = try json(path)
    let vectors = doc["vectors"] as! [[String: Any]]
    var n = 0
    for v in vectors {
        guard v["protocol_name"] as? String == "Noise_XX_25519_ChaChaPoly_SHA256" else { continue }
        let s = { (k: String) in v[k] as! String }
        let src = (s("source").split(separator: " ").first).map(String.init) ?? "?"
        let ini = Noise.HandshakeXX(initiator: true, s: try key(s("init_static")), prologue: Data(hex: s("init_prologue"))!, ephemeral: try key(s("init_ephemeral")))
        let res = Noise.HandshakeXX(initiator: false, s: try key(s("resp_static")), prologue: Data(hex: s("resp_prologue"))!, ephemeral: try key(s("resp_ephemeral")))
        var ti: (send: Noise.CipherState, recv: Noise.CipherState)?
        var tr: (send: Noise.CipherState, recv: Noise.CipherState)?
        var ok = true
        for (i, m) in (v["messages"] as! [[String: String]]).enumerated() {
            let pt = Data(hex: m["payload"]!)!, ct = Data(hex: m["ciphertext"]!)!
            let initSends = i % 2 == 0
            if i < 3 {
                let (a, b) = initSends ? (ini, res) : (res, ini)
                let out = try a.writeMessage(pt)
                ok = ok && out == ct
                let back = try b.readMessage(out); ok = ok && back == pt
                if i == 2 {
                    ok = ok && ini.isFinished && res.isFinished && ini.handshakeHash == res.handshakeHash
                    if let h = v["handshake_hash"] as? String { ok = ok && ini.handshakeHash.hex == h }
                    let rsExpected = try key(s("resp_static")).publicKey.rawRepresentation; ok = ok && ini.rs == rsExpected
                    ti = ini.split(); tr = res.split()
                }
            } else if initSends {
                let out = ti!.send.encrypt(ad: Data(), pt)
                let back = try tr!.recv.decrypt(ad: Data(), out); ok = ok && out == ct && back == pt
            } else {
                let out = tr!.send.encrypt(ad: Data(), pt)
                let back = try ti!.recv.decrypt(ad: Data(), out); ok = ok && out == ct && back == pt
            }
        }
        check(ok, "official vector \(src): \((v["messages"] as! [Any]).count) messages, both roles")
        n += 1
    }
    check(n >= 3, "cacophony + noise-c + snow vectors present (\(n))")

    // Tampering, order, prologue binding, low-order keys.
    let a = Noise.HandshakeXX(initiator: true, s: .init(), prologue: Data("p".utf8))
    let b = Noise.HandshakeXX(initiator: false, s: .init(), prologue: Data("p".utf8))
    check((try? a.readMessage(Data(count: 64))) == nil, "read out of turn rejected")
    _ = try b.readMessage(try a.writeMessage())
    var m2 = try b.writeMessage(Data("hi".utf8))
    m2[40] ^= 1
    check((try? a.readMessage(m2)) == nil, "tampered msg2 rejected")
    let c = Noise.HandshakeXX(initiator: true, s: .init(), prologue: Data("p1".utf8))
    let d = Noise.HandshakeXX(initiator: false, s: .init(), prologue: Data("p2".utf8))
    _ = try d.readMessage(try c.writeMessage())
    check((try? c.readMessage(try d.writeMessage())) == nil, "prologue mismatch breaks msg2")
    let e = Noise.HandshakeXX(initiator: false, s: .init(), prologue: Data())
    _ = try e.readMessage(Data(count: 32))
    check((try? e.writeMessage()) == nil, "low-order (all-zero) ephemeral rejected")
}

/// Replays a transcript (Python reference or Rust-generated) with the Swift engines.
func transcriptTests(_ path: String) throws {
    let label = URL(fileURLWithPath: path).lastPathComponent
    print("handshake transcript (\(label)):")
    let doc = try json(path)
    let vs = try key(doc["viewer_static"] as! String), hs = try key(doc["host_static"] as! String)
    check(vs.publicKey.rawRepresentation.hex == doc["viewer_static_pub"] as! String && hs.publicKey.rawRepresentation.hex == doc["host_static_pub"] as! String, "\(label): static public keys")
    check(GlideHandshake.fingerprint(vs.publicKey.rawRepresentation) == doc["viewer_fingerprint"] as! String
          && GlideHandshake.fingerprint(hs.publicKey.rawRepresentation) == doc["host_fingerprint"] as! String, "\(label): fingerprints")
    for sess in doc["sessions"] as! [[String: Any]] {
        let s = { (k: String) in sess[k] as! String }
        let kind = s("kind")
        let tag = "\(label) \(kind)"
        let flights = (sess["flights"] as! [[String: String]]).map { Data(hex: $0["bytes"]!)! }

        // Host engine (what glide-host runs) fed the viewer's bytes.
        let f0 = flights[0]
        let host = try GlideHandshake.Host(identity: hs, preamble: f0.prefix(24), msg1: f0.dropFirst(26),
                                           ephemeral: try key(s("host_ephemeral")), nonce: Data(hex: s("host_nonce"))!)
        let out2 = try host.writeMsg2(flags: UInt8(sess["host_flags"] as! Int))
        check(out2 == flights[1], "\(tag): host writes HostPreamble + msg2 byte for byte")
        let msg3 = Data(hex: s("msg3"))!
        let (vk, vinfo) = try host.readMsg3(msg3)
        check(vk == vs.publicKey.rawRepresentation && vinfo.name == s("viewer_name") && vinfo.nonce.hex == s("viewer_nonce")
              && vinfo.flags == UInt8(sess["viewer_flags"] as! Int), "\(tag): host reads the viewer's key, name, nonce, flags")
        let he = host.finish()
        check(he.handshakeHash.hex == s("handshake_hash"), "\(tag): handshake hash")
        check(he.recvKeyData.hex == s("c2s_key") && he.sendKeyData.hex == s("s2c_key"), "\(tag): transport keys (host)")

        // Viewer engine (glide-probe) produces the viewer's bytes.
        let viewer = GlideHandshake.Viewer(identity: vs, name: s("viewer_name"), ephemeral: try key(s("viewer_ephemeral")), nonce: Data(hex: s("viewer_nonce"))!)
        check(viewer.firstFlight() == flights[0], "\(tag): viewer writes ClientPreamble + msg1 byte for byte")
        let ver = try GlideHandshake.parseHostPreamble(flights[1].prefix(8))
        let (hk, hinfo) = try viewer.readMsg2(flights[1].dropFirst(10), preambleVersion: ver)
        check(hk == hs.publicKey.rawRepresentation && hinfo.commitment.hex == s("commitment") && hinfo.flags == UInt8(sess["host_flags"] as! Int), "\(tag): viewer reads the host key + commitment")
        let f3 = viewer.writeMsg3(flags: UInt8(sess["viewer_flags"] as! Int))
        check(f3 == GlideHandshake.frame(msg3) && flights[2].prefix(f3.count) == f3, "\(tag): viewer writes msg3 byte for byte")
        let ve = viewer.finish()
        check(ve.sendKeyData == he.recvKeyData && ve.recvKeyData == he.sendKeyData && ve.handshakeHash == he.handshakeHash, "\(tag): both sides agree")
        let sas = GlideHandshake.sasCode(handshakeHash: he.handshakeHash, viewerNonce: vinfo.nonce, hostNonce: host.nonce)
        check(GlideHandshake.sasText(sas) == s("sas") && GlideHandshake.commitment(host.nonce).hex == s("commitment"), "\(tag): SAS \(s("sas")) + commitment")

        // Records in order, per direction; every plaintext decodes and re-encodes.
        let c2s = RecordCipher(key: ve.sendKey), s2c = RecordCipher(key: he.sendKey)
        let c2sOpen = RecordCipher(key: he.recvKey), s2cOpen = RecordCipher(key: ve.recvKey)
        var recOK = true, msgOK = true
        for r in sess["records"] as! [[String: String]] {
            let pt = Data(hex: r["plaintext"]!)!, rec = Data(hex: r["record"]!)!
            let up = r["dir"] == "c2s"
            let sealed = (up ? c2s : s2c).seal(pt)
            let opened = try (up ? c2sOpen : s2cOpen).open(rec.dropFirst(4)); recOK = recOK && sealed == rec && opened == pt
            if up {
                let m = try ClientMessage.decode(pt)
                msgOK = msgOK && m.encoded == pt
            } else {
                let m = try HostMessage.decode(pt)
                msgOK = msgOK && m.encoded == pt
                if case .pairReveal(let n) = m { msgOK = msgOK && n == host.nonce }
            }
        }
        check(recOK, "\(tag): \((sess["records"] as! [Any]).count) records seal/open byte for byte")
        check(msgOK, "\(tag): auth-phase + hello messages decode/re-encode")
        let wrong = RecordCipher(key: SymmetricKey(size: .bits256))
        check((try? wrong.open(Data(hex: (sess["records"] as! [[String: String]])[0]["record"]!)!.dropFirst(4))) == nil, "\(tag): wrong key rejected")
    }
}

func wireUnitTests() throws {
    print("handshake framing:")
    let cp = GlideHandshake.clientPreamble()
    check(cp.hex == "474c443202000200" + String(repeating: "00", count: 16), "ClientPreamble bytes")
    check(cp.count + 2 + 32 >= GlideHandshake.v1ClientSize, "first flight ≥ 54 bytes (a v1 host fails fast on the magic)")
    check((try GlideHandshake.parseHostPreamble(GlideHandshake.hostPreamble(status: 0))) == 2, "HostPreamble ok")
    do { _ = try GlideHandshake.parseHostPreamble(GlideHandshake.hostPreamble(status: 3)); check(false, "status 3 must throw") }
    catch GlideHandshake.HandshakeError.status(_, let st) { check(st == 3, "HostPreamble status 3 = rate limited") }
    let v1 = GlideHandshake.v1Rejection()
    check(v1.count == 70 && v1.prefix(6).hex == "474c44310200", "v1 rejection: GLD1 + version 2, 70 bytes")
    do { _ = try GlideHandshake.parseClientPreamble(Data("GLD1".utf8) + Data(count: 20)); check(false, "v1 preamble must throw") }
    catch GlideHandshake.HandshakeError.badMagic(let isV1) { check(isV1, "ClientPreamble with GLD1 → badMagic(v1)") }
    // Version range negotiation: a viewer that only speaks v3+ is refused with status 1.
    var w = ByteWriter(); w.bytes(GlideHandshake.magic); w.u16(4); w.u16(3); w.bytes(Data(count: 16))
    do { _ = try GlideHandshake.Host(identity: .init(), preamble: w.data, msg1: Data(count: 32)); check(false, "v3-only viewer must be refused") }
    catch GlideHandshake.HandshakeError.status(_, let st) { check(st == 1, "no common version → status 1") }
    let long = GlideHandshake.ViewerInfo(flags: 1, nonce: Data(count: 32), name: String(repeating: "é", count: 200))
    let back = try GlideHandshake.ViewerInfo.decode(long.encoded)
    check(back.name.utf8.count <= 255 && back.name.allSatisfy { $0 == "é" }, "viewer name truncated to 255 bytes on a character boundary")
    check(GlideHandshake.sasText(7) == "000 007" && GlideHandshake.sasText(123_456) == "123 456", "SAS formatting")
    check(HostMessage.authResult(.unknownViewer).encoded.hex == "0501" && ClientMessage.pairConfirm(true).encoded.hex == "0701", "AuthResult / PairConfirm bytes")
}

func pairingLogicTests() {
    print("pairing logic:")
    var v = PairingVote()
    check(v.outcome == .pending, "vote: pending")
    v.viewer = true
    check(v.outcome == .pending, "vote: viewer yes alone is not enough")
    v.local = true
    check(v.outcome == .paired, "vote: both yes → paired")
    v = PairingVote(); v.local = true; v.viewer = false
    check(v.outcome == .declinedByViewer, "vote: viewer no")
    v = PairingVote(); v.local = false
    check(v.outcome == .declinedHere, "vote: Mac no")

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let w = PairingWindow()
    check(w.claim(1, now: t0) == .closed, "window: closed by default")
    w.open(now: t0)
    check(w.isOpen(now: t0.addingTimeInterval(119)) && !w.isOpen(now: t0.addingTimeInterval(121)), "window: 2 minutes")
    check(w.claim(1, now: t0) == .granted && w.claim(2, now: t0) == .busy, "window: one pairing at a time")
    w.release(1, paired: false)
    check(w.isOpen(now: t0) && w.claim(2, now: t0) == .granted, "window: failed pairing leaves it open")
    w.release(2, paired: true)
    check(!w.isOpen(now: t0) && w.claim(3, now: t0) == .closed, "window: success closes it")
    w.open(now: t0)
    check(w.claim(4, now: t0.addingTimeInterval(130)) == .closed, "window: expired")

    let b = HandshakeBackoff()
    check(b.blocked("192.168.10.9", now: t0) == nil, "backoff: clean")
    let ds = (0..<9).map { _ in Int(b.failed("192.168.10.9", now: t0)) }
    check(ds == [1, 2, 4, 8, 16, 32, 60, 60, 60], "backoff: 1 s doubling to 60 s \(ds)")
    check(b.blocked("::ffff:192.168.10.9", now: t0.addingTimeInterval(59)) != nil, "backoff: v4-mapped shares the bucket")
    check(b.blocked("192.168.10.10", now: t0) == nil, "backoff: per IPv4 address")
    b.failed("2001:db8:1:2::1", now: t0)
    check(b.blocked("2001:db8:1:2:ffff::9", now: t0) != nil && b.blocked("2001:db8:1:3::1", now: t0) == nil, "backoff: IPv6 per /64")
    check(HandshakeBackoff.key("fe80::1%en0") == "fe80::/64", "backoff: zone stripped")
    b.succeeded("192.168.10.9")
    check(b.blocked("192.168.10.9", now: t0) == nil, "backoff: success clears")
    b.reset()
    check(b.blocked("2001:db8:1:2::1", now: t0) == nil, "backoff: reset (pairing window opened)")

    let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
    var list = PairedViewers.adding([], name: "PC\u{7}\n", key: k1, at: t0)
    list = PairedViewers.adding(list, name: "Laptop", key: k2, at: t0)
    list = PairedViewers.adding(list, name: "PC renamed", key: k1, at: t0)
    check(list.count == 2 && list.last?.name == "PC renamed" && PairedViewers.contains(list, key: k1), "paired list: re-pairing refreshes the entry")
    check(PairedViewer.displayName("PC\u{7}\n") == "PC" && PairedViewer.displayName(String(repeating: "x", count: 60)).count == 40, "paired list: display names sanitized")
    check(!PairedViewers.contains(PairedViewers.removing(list, key: k2.hex.uppercased()), key: k2), "paired list: remove by key")
    let decoded = try? JSONDecoder().decode([PairedViewer].self, from: JSONEncoder().encode(list))
    check(decoded == list && list[0].paired == "1970-01-12T13:46:40Z", "paired list: JSON round trip, ISO 8601 dates")
}

/// SecureChannel over loopback TCP: v2 host ↔ v2 viewer, a v1 viewer, a rate-limited viewer.
func channelTests() throws {
    print("secure channel (loopback):")
    let q = DispatchQueue(label: "selftest.channel")
    let listener = try NWListener(using: SecureChannel.tcpParameters(), on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    var hostResult: Result<SecureChannel.HostAccepted, Error>?
    var hostChannel: SecureChannel?
    var admission: (UInt16, UInt8) = (0, GlideHandshake.hostFlagPairingOpen)
    let hostDone = DispatchSemaphore(value: 0)
    let hostKey = Curve25519.KeyAgreement.PrivateKey()
    listener.newConnectionHandler = { conn in
        let ch = SecureChannel(connection: conn, queue: q)
        hostChannel = ch
        conn.stateUpdateHandler = { st in
            if case .ready = st {
                ch.acceptHandshake(identity: hostKey, admission: { admission }) { r in hostResult = r; hostDone.signal() }
            }
        }
        conn.start(queue: q)
    }
    listener.start(queue: q)
    _ = ready.wait(timeout: .now() + 5)
    let port = listener.port!

    // 1. v2 viewer (SecureChannel client side) ↔ host: pairing request, then records both ways.
    let viewerKey = Curve25519.KeyAgreement.PrivateKey()
    let vconn = NWConnection(host: "127.0.0.1", port: port, using: SecureChannel.tcpParameters())
    let vch = SecureChannel(connection: vconn, queue: DispatchQueue(label: "selftest.viewer"))
    var viewerResult: Result<SecureChannel.ViewerConnected, Error>?
    let viewerDone = DispatchSemaphore(value: 0)
    vconn.stateUpdateHandler = { st in
        if case .ready = st {
            vch.performHandshake(identity: viewerKey, name: "loopback-viewer", pinned: nil) { r in viewerResult = r; viewerDone.signal() }
        }
    }
    vconn.start(queue: DispatchQueue(label: "selftest.viewer"))
    _ = viewerDone.wait(timeout: .now() + 5)
    _ = hostDone.wait(timeout: .now() + 5)
    if case .success(let acc)? = hostResult, case .success(let vc)? = viewerResult {
        check(acc.viewerKey == viewerKey.publicKey.rawRepresentation && acc.info.name == "loopback-viewer" && acc.info.pairRequest, "host learns the viewer's key + pair request")
        check(vc.hostKey == hostKey.publicKey.rawRepresentation && vc.hostInfo.pairingOpen && vc.pairing, "viewer learns the host key + pairing-open flag")
        check(acc.handshakeHash == vc.handshakeHash && GlideHandshake.commitment(acc.hostNonce) == vc.hostInfo.commitment, "same handshake hash; commitment opens")
        // records
        let got = DispatchSemaphore(value: 0)
        var hostGot: Data?, viewerGot: Data?
        hostChannel?.onMessage = { hostGot = $0; got.signal() }
        vch.onMessage = { viewerGot = $0; got.signal() }
        hostChannel?.startReceiving(); vch.startReceiving()
        vch.send(ClientMessage.pairConfirm(true).encoded)
        hostChannel?.send(HostMessage.authResult(.ok).encoded)
        _ = got.wait(timeout: .now() + 3); _ = got.wait(timeout: .now() + 3)
        check(hostGot == ClientMessage.pairConfirm(true).encoded && viewerGot == HostMessage.authResult(.ok).encoded, "records flow both ways after the handshake")
    } else {
        check(false, "loopback handshake: host \(String(describing: hostResult)), viewer \(String(describing: viewerResult))")
    }
    vch.close(); hostChannel?.close()

    // 2. A pinned viewer that sees a different host key aborts before msg3.
    hostResult = nil
    let v2 = NWConnection(host: "127.0.0.1", port: port, using: SecureChannel.tcpParameters())
    let v2ch = SecureChannel(connection: v2, queue: DispatchQueue(label: "selftest.viewer2"))
    v2.stateUpdateHandler = { st in
        if case .ready = st {
            v2ch.performHandshake(identity: viewerKey, name: "x", pinned: Data(repeating: 9, count: 32)) { r in viewerResult = r; viewerDone.signal(); v2ch.close() }
        }
    }
    v2.start(queue: DispatchQueue(label: "selftest.viewer2"))
    _ = viewerDone.wait(timeout: .now() + 5)
    _ = hostDone.wait(timeout: .now() + 5)
    if case .failure(SecureChannel.ViewerFailure.hostKeyChanged)? = viewerResult, case .failure? = hostResult {
        check(true, "pinned viewer aborts on a different host key; host never gets msg3")
    } else { check(false, "key mismatch: viewer \(String(describing: viewerResult)), host \(String(describing: hostResult))") }

    // 3. Rate-limited: HostPreamble status 3, no DH.
    admission = (GlideHandshake.statusRateLimited, 0)
    let v3 = NWConnection(host: "127.0.0.1", port: port, using: SecureChannel.tcpParameters())
    let v3ch = SecureChannel(connection: v3, queue: DispatchQueue(label: "selftest.viewer3"))
    v3.stateUpdateHandler = { st in
        if case .ready = st {
            v3ch.performHandshake(identity: viewerKey, name: "x", pinned: nil) { r in viewerResult = r; viewerDone.signal(); v3ch.close() }
        }
    }
    v3.start(queue: DispatchQueue(label: "selftest.viewer3"))
    _ = viewerDone.wait(timeout: .now() + 5)
    _ = hostDone.wait(timeout: .now() + 5)
    if case .failure(GlideHandshake.HandshakeError.status(_, 3))? = viewerResult, case .failure(SecureChannel.HandshakeFailure.refused(3))? = hostResult {
        check(true, "rate-limited viewer gets HostPreamble status 3")
    } else { check(false, "rate limit: viewer \(String(describing: viewerResult)), host \(String(describing: hostResult))") }
    admission = (0, 0)

    // 4. A v1 viewer (54-byte GLD1 ClientHandshake) gets 70 bytes "GLD1" + version 2.
    let v1 = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    var v1Reply: Data?
    let v1Done = DispatchSemaphore(value: 0)
    v1.stateUpdateHandler = { st in
        if case .ready = st {
            var hs = Data("GLD1".utf8); hs.append(contentsOf: [1, 0]); hs.append(Data(count: 48))
            v1.send(content: hs, completion: .contentProcessed { _ in })
            v1.receive(minimumIncompleteLength: 70, maximumLength: 70) { d, _, _, _ in v1Reply = d; v1Done.signal() }
        }
    }
    v1.start(queue: DispatchQueue(label: "selftest.v1"))
    _ = v1Done.wait(timeout: .now() + 5)
    _ = hostDone.wait(timeout: .now() + 5)
    var hostSaysV1 = false
    if case .failure(SecureChannel.HandshakeFailure.v1Viewer)? = hostResult { hostSaysV1 = true }
    check(v1Reply?.count == 70 && v1Reply?.prefix(6).hex == "474c44310200" && hostSaysV1, "v1 viewer is told “version 2” and logged as v1")
    v1.cancel()
    listener.cancel()
}

func controlSocketTests() throws {
    print("control socket:")
    let path = NSTemporaryDirectory() + "glide-selftest-\(getpid()).sock"
    let server = ControlServer(path: path) { line, c in
        if line == "ping" { c.send("pong") } else if line == "multi" { c.send("a"); c.send("b\nc"); c.send("end") }
    }
    try server.start()
    var st = stat()
    stat(path, &st)
    check(st.st_mode & 0o777 == 0o600, "socket is 0600")
    let c = try ControlClient(path: path)
    c.send("ping")
    check(c.readLine() == "pong", "request/reply")
    c.send("multi")
    check([c.readLine(), c.readLine(), c.readLine()] == ["a", "b c", "end"], "multi-line reply, newlines escaped")
    c.close()
    let second = ControlServer(path: path) { _, _ in }
    var refused = false
    do { try second.start() } catch { refused = true }
    check(refused, "a second server can't steal a live socket")
    server.stop()
    check(!FileManager.default.fileExists(atPath: path), "stop removes the socket file")
}
