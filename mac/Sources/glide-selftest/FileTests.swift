import CryptoKit
import Darwin
import Foundation
import GlideCore

// File transfer (PROTOCOL.md §6): shared vectors (docs/file-transfer-vectors.json), receiver
// safety (no overwrite, verification, quarantine), sender walk, and an engine loopback.

struct FileVectors: Decodable {
    struct Msg: Decodable { let name: String; let hex: String }
    struct PathV: Decodable { let `in`: String; let out: [String]? }
    struct Suffix: Decodable { let name: String; let n: Int; let dir: Bool; let out: String }
    let messages: [Msg]
    let paths: [PathV]
    let suffix: [Suffix]
}

func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glide-selftest-\(tag)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func listAll(_ d: URL) -> [String] {
    (FileManager.default.enumerator(atPath: d.path)?.allObjects as? [String] ?? []).sorted()
}

func pseudoRandom(_ n: Int, seed: UInt32) -> Data {
    var x = seed
    var d = Data(count: n)
    d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
        for i in 0..<n { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = UInt8(truncatingIfNeeded: x) }
    }
    return d
}

func fileTests(vectorsDir: URL) throws {
    let v = try JSONDecoder().decode(FileVectors.self, from: Data(contentsOf: vectorsDir.appendingPathComponent("file-transfer-vectors.json")))

    // Messages: reference bytes, both message enums.
    let sha = Data(SHA256.hash(data: Data("hello".utf8)))
    let cases: [String: FileMessage] = [
        "FileCaps": .caps(flags: 3, maxTotalBytes: 8 << 30, maxFiles: 10000),
        "FileOffer": .offer(id: 1, totalBytes: 5, files: [FileEntry(path: "Photos/a.jpg", size: 5, mtimeMs: 1_700_000_000_123), FileEntry(path: "b.txt", size: 0, mtimeMs: -1)]),
        "FileAnswer": .answer(id: 1, status: 0, detail: ""),
        "FileAnswerDecline": .answer(id: 0x8000_0002, status: 2, detail: "max 1 GiB"),
        "FileChunk": .chunk(id: 1, index: 0, offset: 0, data: Data("hello".utf8)),
        "FileEnd": .end(id: 1, index: 0, sha256: sha),
        "FileAck": .ack(id: 1, bytes: 5),
        "FileCancel": .cancel(id: 0x8000_0001, reason: 7, detail: "user"),
        "FileDone": .done(id: 1, files: 2),
        "FilePull": .pull,
        "FilePullResult": .pullResult(status: 11, detail: "no files"),
    ]
    check(cases.count == v.messages.count, "file vectors: one case per reference message")
    for m in v.messages {
        guard let want = Data(hex: m.hex), let msg = cases[m.name] else { check(false, "file vector \(m.name) known"); continue }
        var ok = msg.encoded == want && ClientMessage.file(msg).encoded == want && HostMessage.file(msg).encoded == want
        if case let .file(d)? = try? ClientMessage.decode(want) { ok = ok && d == msg } else { ok = false }
        if case let .file(d)? = try? HostMessage.decode(want) { ok = ok && d == msg } else { ok = false }
        // Truncations fail (a chunk's payload is open-ended).
        for n in 1..<want.count where !(m.name == "FileChunk" && n >= 17) {
            if (try? HostMessage.decode(want.prefix(n))) != nil { ok = false }
        }
        check(ok, "file message \(m.name) matches reference bytes")
    }
    // Huge declared count: rejected without allocating.
    var huge = ByteWriter(); huge.u8(0x71); huge.u32(1); huge.u64(0); huge.u32(UInt32.max)
    check((try? FileMessage.decode(huge.data)) == nil, "FileOffer with a bogus count is rejected")

    // Sanitizer vectors (shared with Rust and Python).
    var bad: [String] = []
    for p in v.paths {
        let got = try? FileNames.sanitizePath(p.in)
        let same = (got == nil && p.out == nil) || (got != nil && p.out != nil && got!.map { Array($0.utf8) } == p.out!.map { Array($0.utf8) })
        if !same { bad.append("\(p.in.prefix(40)) -> \(String(describing: got))") }
    }
    check(bad.isEmpty, "\(v.paths.count) path sanitizer vectors" + (bad.isEmpty ? "" : ": " + bad.joined(separator: "; ")))
    check(v.suffix.allSatisfy { FileNames.withSuffix($0.name, $0.n, isDir: $0.dir) == $0.out }, "collision suffix vectors")
    // A combining mark right after "/" must not hide the separator.
    check((try? FileNames.sanitizePath("a/\u{301}../x"))?.map { Array($0.utf8) } == [Array("a".utf8), Array("\u{301}".utf8), Array("x".utf8)], "separator followed by a combining mark")
    check((try? FileNames.sanitizePath("a/..\u{301}/x")) != nil && (try? FileNames.sanitizePath("../\u{301}")) == nil, "dot components compared as bytes")

    // Offer validation.
    let lim = FileLimits(maxTotalBytes: 100, maxFiles: 3)
    func st(_ r: Result<[[String]], FileFailure>) -> UInt8 { if case let .failure(f) = r { return f.status }; return 0 }
    let e = { (p: String, s: UInt64) in FileEntry(path: p, size: s, mtimeMs: 0) }
    check(st(FileOffers.validate(id: 1, total: 3, files: [e("a/b", 1), e("a/c", 2)], limits: lim, fromHost: false)) == 0, "offer: valid")
    check(st(FileOffers.validate(id: 0x8000_0001, total: 1, files: [e("a", 1)], limits: lim, fromHost: false)) == FileStatus.protocolError, "offer: host id from viewer")
    check(st(FileOffers.validate(id: 1, total: 9, files: [e("a", 1)], limits: lim, fromHost: false)) == FileStatus.protocolError, "offer: bad total")
    check(st(FileOffers.validate(id: 1, total: 0, files: [e("a", .max), e("b", 1)], limits: lim, fromHost: false)) == FileStatus.protocolError, "offer: size overflow")
    check(st(FileOffers.validate(id: 1, total: 101, files: [e("a", 101)], limits: lim, fromHost: false)) == FileStatus.tooLarge, "offer: too large")
    check(st(FileOffers.validate(id: 1, total: 0, files: (0..<4).map { e("f\($0)", 0) }, limits: lim, fromHost: false)) == FileStatus.tooLarge, "offer: too many files")
    check(st(FileOffers.validate(id: 1, total: 1, files: [e("../x", 1)], limits: lim, fromHost: false)) == FileStatus.badName, "offer: traversal refused")
    check(st(FileOffers.validate(id: 1, total: 2, files: [e("d", 1), e("D/x", 1)], limits: lim, fromHost: false)) == FileStatus.badName, "offer: file/folder clash")

    // Receiver: never overwrite, fresh top-level folder, quarantine, verification.
    let root = tempDir("in")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("existing".utf8).write(to: root.appendingPathComponent("a.txt"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: false)
    let files = [e("a.txt", 5), e("Photos/sub/x.jpg", 3), e("Photos/empty", 0)]
    let rel = try FileOffers.validate(id: 1, total: 8, files: files, limits: FileLimits(), fromHost: false).get()
    let inc = try FileIncoming(id: 1, root: root, entries: files, rel: rel)
    try inc.chunk(index: 0, offset: 0, data: Data("hel".utf8))
    check((try? inc.chunk(index: 0, offset: 1, data: Data("x".utf8))) == nil, "incoming: non-contiguous offset refused")
    try inc.chunk(index: 0, offset: 3, data: Data("lo".utf8))
    check((try? inc.chunk(index: 0, offset: 5, data: Data("!".utf8))) == nil, "incoming: data past the declared size refused")
    let a2 = try inc.end(index: 0, sha256: Data(SHA256.hash(data: Data("hello".utf8))))
    check(a2.lastPathComponent == "a (2).txt" && (try? String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)) == "existing", "incoming: existing file not overwritten (a (2).txt)")
    check((try? inc.chunk(index: 2, offset: 0, data: Data("z".utf8))) == nil, "incoming: out-of-order file refused")
    try inc.chunk(index: 1, offset: 0, data: Data("jpg".utf8))
    try inc.end(index: 1, sha256: Data(SHA256.hash(data: Data("jpg".utf8))))
    try inc.end(index: 2, sha256: Data(SHA256.hash(data: Data())))
    check(inc.allDone && FileManager.default.fileExists(atPath: root.appendingPathComponent("Photos (2)/sub/x.jpg").path), "incoming: new top-level folder 'Photos (2)'")
    check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Photos").path)) ?? ["x"]).isEmpty, "incoming: existing folder not merged into")
    let q = ["a (2).txt", "Photos (2)", "Photos (2)/sub", "Photos (2)/sub/x.jpg", "Photos (2)/empty"].allSatisfy { Quarantine.read(root.appendingPathComponent($0).path)?.hasPrefix("0081;") == true }
    check(q, "incoming: files and folders carry com.apple.quarantine")
    check(inc.saved.map(\.lastPathComponent) == ["a (2).txt", "Photos (2)"], "incoming: saved top-level items")
    check(!listAll(root).contains { $0.hasSuffix(".part") }, "incoming: no temp files left")
    // Bad SHA-256: nothing left behind.
    let root2 = tempDir("bad")
    defer { try? FileManager.default.removeItem(at: root2) }
    let inc2 = try FileIncoming(id: 2, root: root2, entries: [e("evil.bin", 4)], rel: [["evil.bin"]])
    try inc2.chunk(index: 0, offset: 0, data: Data("evil".utf8))
    var verr: UInt8 = 0
    do { try inc2.end(index: 0, sha256: Data(SHA256.hash(data: Data("good".utf8)))) } catch let f as FileFailure { verr = f.status }
    check(verr == FileStatus.verify && listAll(root2).isEmpty, "incoming: SHA-256 mismatch rejected, nothing left")

    // Hostile modification times are ignored, never fatal.
    check([Int64.max, Int64.min, -1, 0, FileTimes.maxMs + 1].allSatisfy { FileTimes.split($0) == nil }
          && FileTimes.split(1_700_000_000_123)! == (1_700_000_000, 123_000) && FileTimes.split(FileTimes.maxMs) != nil, "mtime range check")
    let root3 = tempDir("mtime")
    defer { try? FileManager.default.removeItem(at: root3) }
    let inc3 = try FileIncoming(id: 3, root: root3, entries: [FileEntry(path: "t.txt", size: 1, mtimeMs: .max), FileEntry(path: "u", size: 0, mtimeMs: .min)], rel: [["t.txt"], ["u"]])
    try inc3.chunk(index: 0, offset: 0, data: Data("x".utf8))
    try inc3.end(index: 0, sha256: Data(SHA256.hash(data: Data("x".utf8))))
    try inc3.end(index: 1, sha256: Data(SHA256.hash(data: Data())))
    check(inc3.allDone, "incoming: files with hostile mtimes are saved, mtime ignored")

    // Sender walk: symlinks and special files refused.
    let src = tempDir("src")
    defer { try? FileManager.default.removeItem(at: src) }
    let folder = src.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try Data("bb".utf8).write(to: folder.appendingPathComponent("deep/er/b.txt"))
    try Data().write(to: folder.appendingPathComponent(".DS_Store"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("etc").path, withDestinationPath: "/etc")
    try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("top-link").path, withDestinationPath: "/etc/hosts")
    mkfifo(folder.appendingPathComponent("fifo").path, 0o644)
    let c = try FileCollector.collect([folder, src.appendingPathComponent("top-link")], limits: FileLimits()).get()
    check(c.files.map(\.entry.path) == ["Folder/a.txt", "Folder/deep/er/b.txt"] && c.total == 3 && c.skipped.count == 3, "collect: symlinks/fifo refused, .DS_Store skipped (\(c.skipped))")
    if case .failure(let f) = FileCollector.collect([folder], limits: FileLimits(maxTotalBytes: 2, maxFiles: 10)) { check(f.status == FileStatus.tooLarge, "collect: size limit") } else { check(false, "collect: size limit") }

    try engineLoopback()
}

/// Two engines (host role <-> viewer role) through the real wire encoding.
func engineLoopback() throws {
    let base = tempDir("loop")
    defer { try? FileManager.default.removeItem(at: base) }
    let hostDl = base.appendingPathComponent("host-dl"), viewerDl = base.appendingPathComponent("viewer-dl"), src = base.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src.appendingPathComponent("Album/nested"), withIntermediateDirectories: true)
    let big = pseudoRandom(3_000_000 + 4321, seed: 7)
    try big.write(to: src.appendingPathComponent("Album/big.bin"))
    try Data("small".utf8).write(to: src.appendingPathComponent("Album/nested/small.txt"))
    try Data().write(to: src.appendingPathComponent("Album/empty.dat"))

    let host = FileTransferEngine(config: .init(downloadDir: hostDl, hostRole: true))
    let viewer = FileTransferEngine(config: .init(downloadDir: viewerDl, hostRole: false))
    host.send = { m, _ in viewer.handle(try! FileMessage.decode(HostMessage.file(m).encoded)) }
    viewer.send = { m, _ in host.handle(try! FileMessage.decode(ClientMessage.file(m).encoded)) }
    // Simulated video backlog: chunks are held back for a while, then flow.
    var backlogPolls = 0
    host.canSendBulk = { backlogPolls += 1; return backlogPolls > 20 }
    let events = DispatchQueue(label: "events")
    var hostEvents: [FileTransferEngine.Event] = [], viewerEvents: [FileTransferEngine.Event] = []
    host.onEvent = { e in events.sync { hostEvents.append(e) } }
    viewer.onEvent = { e in events.sync { viewerEvents.append(e) } }
    host.handle(.caps(flags: 3, maxTotalBytes: 8 << 30, maxFiles: 10000))  // what the viewer accepts
    viewer.handle(.caps(flags: 3, maxTotalBytes: 8 << 30, maxFiles: 10000))

    func waitFor(_ what: String, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(20)
        while Date() < end { if events.sync(execute: cond) { return true }; usleep(10_000) }
        print("    timeout waiting for \(what)")
        return false
    }
    func isReceived(_ e: FileTransferEngine.Event) -> Bool { if case .received = e { return true }; return false }
    func isSent(_ e: FileTransferEngine.Event) -> Bool { if case .sent = e { return true }; return false }
    func isFailed(_ e: FileTransferEngine.Event) -> Bool { if case .failed = e { return true }; return false }

    // Mac -> viewer (host role sends), with the backlog pause.
    host.sendItems([src.appendingPathComponent("Album")])
    check(waitFor("received") { viewerEvents.contains(where: isReceived) && hostEvents.contains(where: isSent) }, "engine: host -> viewer transfer completes despite a video backlog pause")
    check((try? Data(contentsOf: viewerDl.appendingPathComponent("Album/big.bin"))) == big
          && (try? Data(contentsOf: viewerDl.appendingPathComponent("Album/nested/small.txt"))) == Data("small".utf8)
          && FileManager.default.fileExists(atPath: viewerDl.appendingPathComponent("Album/empty.dat").path), "engine: contents verified")
    check(backlogPolls > 20, "engine: chunks waited while canSendBulk was false")

    // Viewer -> Mac: quarantined, no overwrite on repeat.
    viewer.sendItems([src.appendingPathComponent("Album/big.bin")])
    check(waitFor("received 2") { hostEvents.filter(isReceived).count == 1 }, "engine: viewer -> host transfer completes")
    viewer.sendItems([src.appendingPathComponent("Album/big.bin")])
    check(waitFor("received 3") { hostEvents.filter(isReceived).count == 2 }, "engine: second identical transfer completes")
    check((try? Data(contentsOf: hostDl.appendingPathComponent("big (2).bin"))) == big && Quarantine.read(hostDl.appendingPathComponent("big (2).bin").path) != nil,
          "engine: repeat saved as 'big (2).bin', quarantined")

    // Cancel mid-transfer from the receiver: partial file removed, sender told.
    // (The sender is throttled after a few chunks so the cancel lands mid-file.)
    try pseudoRandom(30 << 20, seed: 3).write(to: src.appendingPathComponent("huge.bin"))
    var bulk = 0
    viewer.canSendBulk = { bulk += 1; return bulk <= 3 }
    viewer.sendItems([src.appendingPathComponent("huge.bin")])
    _ = waitFor("started") { hostEvents.contains { if case .started(true, _, _) = $0 { return true }; return false } }
    _ = waitFor("partial file") { listAll(hostDl).contains { $0.hasSuffix(".part") } }
    host.cancelAll()
    check(waitFor("viewer failed") { viewerEvents.contains(where: isFailed) }, "engine: receiver cancel reaches the sender")
    usleep(200_000)
    check(!FileManager.default.fileExists(atPath: hostDl.appendingPathComponent("huge.bin").path) && !listAll(hostDl).contains { $0.hasSuffix(".part") },
          "engine: cancelled transfer leaves no partial file")
    check(!host.busy && !viewer.busy, "engine: idle after cancel")
    host.stop(); viewer.stop()
}
