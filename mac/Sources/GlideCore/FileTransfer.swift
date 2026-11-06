import CryptoKit
import Darwin
import Foundation

// File transfer (PROTOCOL.md §6): receiver (temp file -> SHA-256 verify -> rename, never
// overwriting, quarantined), sender (directory walk refusing symlinks/special files, chunking +
// hashing) and FileTransferEngine, which runs one outgoing and one incoming transfer at a time
// for a session with FileAck flow control. Received files are never opened or executed.

/// Marks a received file or folder as downloaded from the internet (`com.apple.quarantine`), so
/// Gatekeeper checks it when it is opened, exactly like a browser download.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    public static func value(agent: String = "Glide", now: Date = Date()) -> String {
        // flags;hex time;agent;event id (0x0081: downloaded from the internet, not yet approved)
        String(format: "0081;%08x;%@;", UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970)), agent)
    }

    @discardableResult
    public static func mark(_ path: String, agent: String = "Glide") -> Bool {
        let v = Array(value(agent: agent).utf8)
        return setxattr(path, attribute, v, v.count, 0, XATTR_NOFOLLOW) == 0
    }

    public static func read(_ path: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = getxattr(path, attribute, &buf, buf.count, 0, XATTR_NOFOLLOW)
        return n > 0 ? String(decoding: buf[..<n], as: UTF8.self) : nil
    }
}

func errnoText(_ what: String, _ e: Int32 = errno) -> FileFailure {
    FileFailure(e == ENOSPC || e == EDQUOT ? FileStatus.noSpace : FileStatus.io, "\(what): \(String(cString: strerror(e)))")
}

/// One incoming transfer, written under `root`. Each file goes to a hidden temp file in its final
/// folder, is verified (size + SHA-256), quarantined, then renamed into place with RENAME_EXCL
/// (never replacing anything; "a (2).txt" if taken). Each top-level folder of the offer becomes a
/// new folder ("Photos (2)" if "Photos" exists): nothing is merged into an existing folder.
public final class FileIncoming {
    public let id: UInt32
    public let root: URL
    let entries: [FileEntry]
    let rel: [[String]]
    var tops: [String: String] = [:]
    var fd: Int32 = -1
    var tmp = ""
    var dir = ""
    var written: UInt64 = 0
    var hash = SHA256()
    var next = 0
    public private(set) var received: UInt64 = 0
    public let total: UInt64
    /// Top-level items created (files and folders), in order.
    public private(set) var saved: [URL] = []
    var mark: (String) -> Void

    public init(id: UInt32, root: URL, entries: [FileEntry], rel: [[String]], mark: @escaping (String) -> Void = { Quarantine.mark($0) }) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.id = id; self.root = root; self.entries = entries; self.rel = rel; self.mark = mark
        total = entries.reduce(0) { $0 + $1.size }
    }

    deinit { abort() }

    public var fileCount: Int { entries.count }
    public var allDone: Bool { next == entries.count }

    func dirFor(_ index: Int) throws -> String {
        let comps = rel[index]
        if comps.count == 1 { return root.path }
        let top = comps[0]
        if tops[top] == nil {
            var n = 1
            while true {
                let cand = FileNames.withSuffix(top, n, isDir: true)
                let p = root.appendingPathComponent(cand).path
                var st = stat()
                if lstat(p, &st) != 0 {
                    if mkdir(p, 0o755) == 0 {
                        mark(p)
                        saved.append(URL(fileURLWithPath: p, isDirectory: true))
                        tops[top] = cand
                        break
                    }
                    if errno != EEXIST { throw errnoText("cannot create folder") }
                }
                n += 1
                if n > 9999 { throw FileFailure(FileStatus.io, "no free folder name") }
            }
        }
        var d = root.appendingPathComponent(tops[top]!).path
        for c in comps[1..<(comps.count - 1)] {
            d += "/" + c
            if mkdir(d, 0o755) == 0 { mark(d) } else {
                var st = stat()
                guard errno == EEXIST, lstat(d, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw errnoText("cannot create folder") }
            }
        }
        return d
    }

    func open(_ index: Int) throws {
        dir = try dirFor(index)
        tmp = dir + "/" + String(format: ".glide-%08x-%d.part", id, index)
        fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0 { throw errnoText("cannot create file") }
        written = 0
        hash = SHA256()
    }

    func checkIndex(_ index: UInt32) throws {
        if Int(index) != next || Int(index) >= entries.count {
            throw FileFailure(FileStatus.protocolError, "data for file \(index), expected \(next)")
        }
    }

    public func chunk(index: UInt32, offset: UInt64, data: Data) throws {
        try checkIndex(index)
        if fd < 0 { try open(Int(index)) }
        let size = entries[Int(index)].size
        if offset != written || data.isEmpty || data.count > FileMessage.chunkMax || written + UInt64(data.count) > size {
            throw FileFailure(FileStatus.protocolError, "bad chunk (file \(index), offset \(offset), \(data.count) bytes)")
        }
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n < 0 { if errno == EINTR { continue }; throw errnoText("write failed") }
                off += n
            }
        }
        hash.update(data: data)
        written += UInt64(data.count)
        received += UInt64(data.count)
    }

    /// File `index` is complete: verify, quarantine, rename into place. Returns the saved path.
    @discardableResult
    public func end(index: UInt32, sha256: Data) throws -> URL {
        try checkIndex(index)
        if fd < 0 { try open(Int(index)) }  // empty file
        let e = entries[Int(index)]
        let digest = Data(hash.finalize())
        defer { if fd >= 0 { Darwin.close(fd); fd = -1 }; if !tmp.isEmpty { unlink(tmp); tmp = "" } }
        guard written == e.size, digest == sha256 else {
            throw FileFailure(FileStatus.verify, "'\(e.path)' does not match its SHA-256 / size")
        }
        if let t = FileTimes.split(e.mtimeMs) {
            var tv = [timeval(tv_sec: t.sec, tv_usec: t.usec), timeval(tv_sec: t.sec, tv_usec: t.usec)]
            _ = futimes(fd, &tv)
        }
        if fsync(fd) != 0 { throw errnoText("flush failed") }
        Darwin.close(fd); fd = -1
        mark(tmp)
        let name = rel[Int(index)].last!
        var n = 1
        while true {
            let cand = dir + "/" + FileNames.withSuffix(name, n, isDir: false)
            if renamex_np(tmp, cand, UInt32(RENAME_EXCL)) == 0 {
                tmp = ""
                let url = URL(fileURLWithPath: cand)
                if rel[Int(index)].count == 1 { saved.append(url) }
                next += 1
                return url
            }
            if errno != EEXIST || n >= 9999 { throw errnoText("cannot save file") }
            n += 1
        }
    }

    /// Stop: delete the partial file (completed files stay).
    public func abort() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if !tmp.isEmpty { unlink(tmp); tmp = "" }
    }
}

public struct FileSource {
    public var url: URL
    public var entry: FileEntry
}

public struct FileCollection {
    public var files: [FileSource] = []
    /// What was left out and why (symlinks, special files, too deep).
    public var skipped: [String] = []
    public var total: UInt64 = 0
}

public enum FileCollector {
    static func mtimeMs(_ st: stat) -> Int64 { Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000 }

    /// Picked/copied items -> the files to send, folders recursively with relative paths
    /// (names in NFC). Symlinks and special files are refused, never followed.
    public static func collect(_ urls: [URL], limits: FileLimits) -> Result<FileCollection, FileFailure> {
        var out = FileCollection()
        func add(_ url: URL, _ rel: String, _ st: stat) -> FileFailure? {
            out.total += UInt64(st.st_size)
            out.files.append(FileSource(url: url, entry: FileEntry(path: rel, size: UInt64(st.st_size), mtimeMs: mtimeMs(st))))
            if out.files.count > limits.maxFiles { return FileFailure(FileStatus.tooLarge, "more than \(limits.maxFiles) files") }
            if out.total > limits.maxTotalBytes { return FileFailure(FileStatus.tooLarge, "more than \(FileOffers.byteText(limits.maxTotalBytes))") }
            return nil
        }
        func walk(_ dir: URL, _ rel: String, _ depth: Int) -> FileFailure? {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                out.skipped.append("\(rel) (can't read)"); return nil
            }
            for name in names.sorted() {
                if name == ".DS_Store" { continue }
                let u = dir.appendingPathComponent(name)
                let r = rel + "/" + name.precomposedStringWithCanonicalMapping
                var st = stat()
                guard lstat(u.path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFLNK: out.skipped.append("\(r) (link)")
                case S_IFDIR:
                    if depth + 1 >= FileNames.maxDepth { out.skipped.append("\(r) (too deeply nested)") } else if let f = walk(u, r, depth + 1) { return f }
                case S_IFREG: if let f = add(u, r, st) { return f }
                default: out.skipped.append("\(r) (not a regular file)")
                }
            }
            return nil
        }
        for url in urls {
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            var st = stat()
            guard !name.isEmpty, name != "/", lstat(url.path, &st) == 0 else { out.skipped.append("\(url.path) (missing)"); continue }
            switch st.st_mode & S_IFMT {
            case S_IFLNK: out.skipped.append("\(name) (link)")
            case S_IFDIR: if let f = walk(url, name, 1) { return .failure(f) }
            case S_IFREG: if let f = add(url, name, st) { return .failure(f) }
            default: out.skipped.append("\(name) (not a regular file)")
            }
        }
        return .success(out)
    }
}

/// One outgoing transfer: yields chunk/end messages in order, hashing as it reads.
public final class FileOutgoing {
    public let id: UInt32
    let files: [FileSource]
    var idx = 0
    var fd: Int32 = -1
    var pos: UInt64 = 0
    var hash = SHA256()
    public private(set) var sent: UInt64 = 0
    public let total: UInt64

    public init(id: UInt32, _ c: FileCollection) { self.id = id; files = c.files; total = c.total }
    deinit { if fd >= 0 { close(fd) } }

    public var fileCount: Int { files.count }
    public var offer: FileMessage { .offer(id: id, totalBytes: total, files: files.map(\.entry)) }

    /// The next chunk or end message; nil once every file has been sent.
    public func next() throws -> FileMessage? {
        guard idx < files.count else { return nil }
        let f = files[idx]
        let size = f.entry.size
        let changed = { (what: String) in FileFailure(FileStatus.sourceChanged, "'\(f.entry.path)' \(what)") }
        if fd < 0 {
            fd = open(f.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { throw errnoText("cannot read '\(f.entry.path)'") }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, UInt64(st.st_size) == size else { throw changed("changed") }
            pos = 0
            hash = SHA256()
        }
        if pos < size {
            let want = Int(min(size - pos, UInt64(FileMessage.chunkMax)))
            var buf = Data(count: want)
            var got = 0
            try buf.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                while got < want {
                    let n = read(fd, p.baseAddress! + got, want - got)
                    if n < 0 { if errno == EINTR { continue }; throw errnoText("cannot read '\(f.entry.path)'") }
                    if n == 0 { break }
                    got += n
                }
            }
            if got == 0 { throw changed("got shorter while being sent") }
            if got < want { buf = buf.prefix(got) }
            hash.update(data: buf)
            let off = pos
            pos += UInt64(got)
            sent += UInt64(got)
            return .chunk(id: id, index: UInt32(idx), offset: off, data: buf)
        }
        var one: UInt8 = 0
        if read(fd, &one, 1) > 0 { throw changed("grew while being sent") }
        close(fd); fd = -1
        let index = UInt32(idx)
        idx += 1
        return .end(id: id, index: index, sha256: Data(hash.finalize()))
    }
}

/// Runs file transfers for one session (host side, or a test peer). All state lives on `queue`.
public final class FileTransferEngine: @unchecked Sendable {
    public struct Config {
        public var downloadDir: URL
        public var limits: FileLimits
        public var receive: Bool
        /// Our transfer ids get bit 31 (the host); the viewer role is for tests.
        public var hostRole: Bool
        public var mark: (String) -> Void
        public init(downloadDir: URL, limits: FileLimits = FileLimits(), receive: Bool = true, hostRole: Bool = true, mark: @escaping (String) -> Void = { Quarantine.mark($0) }) {
            self.downloadDir = downloadDir; self.limits = limits; self.receive = receive; self.hostRole = hostRole; self.mark = mark
        }
    }

    public enum Event {
        case started(incoming: Bool, files: Int, bytes: UInt64)
        case received(files: Int, bytes: UInt64, dir: URL, items: [URL])
        case sent(files: Int, bytes: UInt64)
        case failed(String)
        case info(String)
    }

    public struct Progress: Equatable {
        public var incoming: Bool
        public var files: Int
        public var done: UInt64
        public var total: UInt64
    }

    enum Phase: Equatable { case offered, sending, waitDone }

    public let queue = DispatchQueue(label: "glide.files", qos: .utility)
    public var config: Config
    /// Sends a message to the peer; `bulk` = a file chunk (low priority).
    public var send: (FileMessage, _ bulk: Bool) -> Void = { _, _ in }
    /// May a chunk be sent right now? (e.g. the connection has no video backlog). Polled.
    public var canSendBulk: () -> Bool = { true }
    public var onEvent: (Event) -> Void = { _ in }

    /// Re-check the bulk gate now (e.g. a chunk left the connection's send queue). Any thread.
    public func kick() { queue.async { [self] in pump() } }
    /// Limits the peer accepts (nil: unknown).
    public var peerLimits: FileLimits?

    var pending: [[URL]] = []
    var out: FileOutgoing?
    var phase: Phase = .offered
    var acked: UInt64 = 0
    var outTimer: DispatchWorkItem?
    var pumpScheduled = false
    var inc: FileIncoming?
    var nextId: UInt32
    var stopped = false
    let lock = NSLock()
    var progressSnapshot: [Progress] = []

    public init(config: Config) {
        self.config = config
        nextId = config.hostRole ? FileMessage.hostIdBit | 1 : 1
    }

    /// Thread-safe snapshot of active transfers.
    public var progress: [Progress] { lock.lock(); defer { lock.unlock() }; return progressSnapshot }
    public var busy: Bool { queue.sync { out != nil || inc != nil || !pending.isEmpty } }

    func publishProgress() {
        var p: [Progress] = []
        if let o = out { p.append(Progress(incoming: false, files: o.fileCount, done: acked, total: o.total)) }
        if let i = inc { p.append(Progress(incoming: true, files: i.fileCount, done: i.received, total: i.total)) }
        lock.lock(); progressSnapshot = p; lock.unlock()
    }

    func ours(_ id: UInt32) -> Bool { id != 0 && FileOffers.isHostId(id) == config.hostRole }

    // MARK: Public API (any thread)

    var queuedChunkBytes: UInt64 = 0
    var overflowed = false

    public func handle(_ m: FileMessage) {
        // Bound memory against a peer that ignores the ack window: chunks wait on `queue`.
        if case let .chunk(id, _, _, data) = m {
            lock.lock()
            let n = UInt64(data.count)
            let drop = overflowed || queuedChunkBytes + n > FileMessage.receiveQueueMax
            let first = drop && !overflowed
            if drop { overflowed = true } else { queuedChunkBytes += n }
            lock.unlock()
            if first {
                queue.async { [self] in
                    guard let i = inc, i.id == id else { return }
                    step(i) { throw FileFailure(FileStatus.protocolError, "the sender ignored flow control") }
                }
            }
            if drop { return }
            queue.async { [self] in
                lock.lock(); queuedChunkBytes -= n; lock.unlock()
                if !stopped { handleOnQueue(m) }
            }
            return
        }
        if case .offer = m { lock.lock(); overflowed = false; lock.unlock() }
        queue.async { [self] in if !stopped { handleOnQueue(m) } }
    }

    public func sendItems(_ urls: [URL]) {
        queue.async { [self] in
            guard !stopped, !urls.isEmpty else { return }
            pending.append(urls)
            startNext()
        }
    }

    /// Cancel everything. Calls `done(true)` if anything was active.
    public func cancelAll(_ done: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let any = out != nil || inc != nil || !pending.isEmpty
            pending.removeAll()
            if let o = out { send(.cancel(id: o.id, reason: FileStatus.cancelled, detail: "cancelled by the user"), false); finishOut(.failed("File transfer cancelled")) }
            if let i = inc { send(.cancel(id: i.id, reason: FileStatus.cancelled, detail: "cancelled by the user"), false); i.abort(); inc = nil; onEvent(.failed("File transfer cancelled")) }
            publishProgress()
            done?(any)
        }
    }

    /// Session ended: drop everything (partial files are deleted).
    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            let active = out != nil || inc != nil
            pending.removeAll()
            outTimer?.cancel()
            out = nil
            inc?.abort(); inc = nil
            publishProgress()
            if active { onEvent(.failed("File transfer interrupted: connection lost")) }
        }
    }

    // MARK: Queue

    func handleOnQueue(_ m: FileMessage) {
        switch m {
        case let .caps(flags, total, n):
            peerLimits = flags & FileMessage.capsReceive != 0 ? FileLimits(maxTotalBytes: total, maxFiles: Int(n)) : nil
        case let .offer(id, total, files): onOffer(id: id, total: total, files: files)
        case let .chunk(id, index, offset, data):
            guard let i = inc, i.id == id else { return }  // late chunk of a cancelled transfer
            step(i) { try i.chunk(index: index, offset: offset, data: data); return nil }
        case let .end(id, index, sha):
            guard let i = inc, i.id == id else { return }
            step(i) { try i.end(index: index, sha256: sha) }
        case let .cancel(id, reason, detail) where !ours(id):
            guard let i = inc, i.id == id else { return }
            i.abort(); inc = nil; publishProgress()
            onEvent(.failed("The viewer stopped sending files (\(detail.isEmpty ? FileStatus.text(reason) : detail))"))
        case let .cancel(id, reason, detail):
            guard let o = out, o.id == id else { return }
            finishOut(.failed("File transfer stopped by the viewer (\(detail.isEmpty ? FileStatus.text(reason) : detail))"))
        case let .answer(id, st, detail):
            guard let o = out, o.id == id, phase == .offered else { return }
            if st == FileStatus.ok {
                phase = .sending
                outTimer?.cancel()
                onEvent(.started(incoming: false, files: o.fileCount, bytes: o.total))
                pump()
            } else {
                finishOut(.failed("Files not sent: the viewer declined (\(FileStatus.text(st))\(detail.isEmpty ? "" : " — " + detail))"))
            }
        case let .ack(id, n):
            guard let o = out, o.id == id else { return }
            acked = max(acked, min(n, o.total))
            publishProgress()
            pump()
        case let .done(id, _):
            guard let o = out, o.id == id else { return }
            finishOut(.sent(files: o.fileCount, bytes: o.total))
        case .pull, .pullResult: break  // handled by the session (pasteboard) / viewer
        }
    }

    func onOffer(id: UInt32, total: UInt64, files: [FileEntry]) {
        let answer = { (st: UInt8, d: String) in self.send(.answer(id: id, status: st, detail: d), false) }
        guard config.receive else { return answer(FileStatus.declined, "receiving files is turned off on this Mac") }
        guard inc == nil else { return answer(FileStatus.busy, "another transfer is in progress") }
        switch FileOffers.validate(id: id, total: total, files: files, limits: config.limits, fromHost: !config.hostRole) {
        case let .failure(f):
            answer(f.status, f.detail)
            onEvent(.failed("Refused files from the viewer: \(f.detail)"))
        case let .success(rel):
            do {
                inc = try FileIncoming(id: id, root: config.downloadDir, entries: files, rel: rel, mark: config.mark)
                answer(FileStatus.ok, "")
                publishProgress()
                onEvent(.started(incoming: true, files: files.count, bytes: total))
            } catch {
                answer(FileStatus.io, "cannot create the download folder: \(error.localizedDescription)")
                onEvent(.failed("Cannot save files to \(config.downloadDir.path): \(error.localizedDescription)"))
            }
        }
    }

    func step(_ i: FileIncoming, _ f: () throws -> URL?) {
        do {
            _ = try f()
            send(.ack(id: i.id, bytes: i.received), false)
            if i.allDone {
                send(.done(id: i.id, files: UInt32(i.fileCount)), false)
                inc = nil
                publishProgress()
                onEvent(.received(files: i.fileCount, bytes: i.total, dir: i.root, items: i.saved))
            } else {
                publishProgress()
            }
        } catch {
            let f = error as? FileFailure ?? FileFailure(FileStatus.io, "\(error)")
            send(.cancel(id: i.id, reason: f.status, detail: f.detail), false)
            i.abort(); inc = nil
            publishProgress()
            onEvent(.failed("File transfer failed: \(f.detail)"))
        }
    }

    func startNext() {
        guard out == nil, !stopped, !pending.isEmpty else { return }
        let urls = pending.removeFirst()
        guard let peer = peerLimits else {
            onEvent(.failed("The viewer doesn't accept files"))
            return startNext()
        }
        let c: FileCollection
        switch FileCollector.collect(urls, limits: config.limits.min(peer)) {
        case let .failure(f): onEvent(.failed("Files not sent: \(f.detail)")); return startNext()
        case let .success(x): c = x
        }
        if !c.skipped.isEmpty { onEvent(.info("Skipped \(FileOffers.fileText(c.skipped.count)) (links or special files): \(c.skipped.joined(separator: ", "))")) }
        if c.files.isEmpty { onEvent(.failed("Nothing to send (only empty folders or links)")); return startNext() }
        let id = nextId
        nextId = nextId &+ 1
        if nextId & ~FileMessage.hostIdBit == 0 || FileOffers.isHostId(nextId) != config.hostRole { nextId = config.hostRole ? FileMessage.hostIdBit | 1 : 1 }
        let o = FileOutgoing(id: id, c)
        out = o; phase = .offered; acked = 0
        publishProgress()
        send(o.offer, false)
        armTimeout(60, "the viewer didn't answer")
    }

    func armTimeout(_ s: Double, _ why: String) {
        outTimer?.cancel()
        let id = out?.id
        let w = DispatchWorkItem { [weak self] in
            guard let self, let o = self.out, o.id == id else { return }
            self.send(.cancel(id: o.id, reason: FileStatus.cancelled, detail: "timed out"), false)
            self.finishOut(.failed("File transfer timed out (\(why))"))
        }
        outTimer = w
        queue.asyncAfter(deadline: .now() + s, execute: w)
    }

    func finishOut(_ e: Event) {
        outTimer?.cancel(); outTimer = nil
        out = nil
        publishProgress()
        onEvent(e)
        startNext()
    }

    /// Send chunks while the ack window and the connection's backlog allow.
    func pump() {
        guard let o = out, phase == .sending else { return }
        while o.sent - min(acked, o.sent) + UInt64(FileMessage.chunkMax) <= FileMessage.sendWindow {
            guard canSendBulk() else {
                // Video backlog: retry shortly (chunks only use spare capacity).
                if !pumpScheduled {
                    pumpScheduled = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(3)) { [weak self] in self?.pumpScheduled = false; self?.pump() }
                }
                return
            }
            do {
                guard let m = try o.next() else {
                    phase = .waitDone
                    armTimeout(120, "no confirmation from the viewer")
                    return
                }
                if case .chunk = m { send(m, true) } else { send(m, false) }
            } catch {
                let f = error as? FileFailure ?? FileFailure(FileStatus.io, "\(error)")
                send(.cancel(id: o.id, reason: f.status, detail: f.detail), false)
                return finishOut(.failed("File transfer failed: \(f.detail)"))
            }
        }
    }
}
