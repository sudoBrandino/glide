import AppKit
import Foundation
import GlideCore
import UserNotifications

/// Resolved file-transfer settings.
struct HostFileConfig {
    var enabled = true
    var receive = true
    var downloadDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Glide", isDirectory: true)
    var limits = FileLimits()

    init() {}
    init(_ s: FileSettings?) {
        guard let s else { return }
        enabled = s.enabled ?? true
        receive = s.receive ?? true
        if let d = s.downloadDir, !d.trimmingCharacters(in: .whitespaces).isEmpty {
            downloadDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        limits = FileLimits(maxTotalBytes: s.maxTotalBytes ?? limits.maxTotalBytes, maxFiles: s.maxFiles ?? limits.maxFiles)
    }
}

/// One session's file transfers: the engine, wired to the channel with chunk pacing, plus the
/// pasteboard pull (Ctrl+Alt+Shift+V on the viewer).
final class SessionFiles: @unchecked Sendable {
    let engine: FileTransferEngine
    let sessionId: Int
    let viewerName: String
    let config: HostFileConfig
    /// Chunks only go out while the connection's backlog is below this (video first).
    static let bulkBacklogLimit = 256 * 1024
    /// FileCaps flags (managed sessions narrow them to the session's permissions).
    let capsFlags: UInt32
    /// Mac -> viewer allowed (managed sessions: files `to_viewer` or `both`).
    let allowSend: Bool
    /// Finished transfers (managed sessions: the audit event).
    var onAudit: ((_ sent: Bool, _ count: Int, _ bytes: UInt64, _ names: [String]) -> Void)?
    private var lastSentNames: [String] = []

    /// `send(message, onSent)`: `onSent` (chunks only) runs once the bytes left the send queue.
    init(sessionId: Int, viewerName: String, config: HostFileConfig, capsFlags: UInt32? = nil, allowSend: Bool = true,
         send: @escaping (FileMessage, (() -> Void)?) -> Void, backlog: @escaping () -> Int) {
        self.sessionId = sessionId
        self.viewerName = viewerName
        self.config = config
        self.capsFlags = capsFlags ?? ((config.receive ? FileMessage.capsReceive : 0) | FileMessage.capsSend)
        self.allowSend = allowSend
        engine = FileTransferEngine(config: .init(downloadDir: config.downloadDir, limits: config.limits, receive: config.receive, hostRole: true))
        engine.send = { [weak e = engine] m, bulk in send(m, bulk ? { e?.kick() } : nil) }
        engine.canSendBulk = { backlog() < SessionFiles.bulkBacklogLimit }
        // The viewer advertises no limits of its own: it declines what it won't take.
        engine.peerLimits = FileLimits(maxTotalBytes: .max, maxFiles: .max)
        engine.onEvent = { [weak self] e in self?.on(e) }
    }

    func log(_ s: String) { glideFilesLog("session \(sessionId): files: \(s)") }

    /// FileCaps for the viewer (sent right after ServerHello).
    var caps: FileMessage {
        .caps(flags: capsFlags,
              maxTotalBytes: config.limits.maxTotalBytes, maxFiles: UInt32(clamping: config.limits.maxFiles))
    }

    func handle(_ m: FileMessage) {
        switch m {
        case .pull: pull()
        case let .offer(id, total, files):
            log("<- offer \(String(format: "%08x", id)): \(FileOffers.fileText(files.count)), \(FileOffers.byteText(total))")
            engine.handle(m)
        default: engine.handle(m)
        }
    }

    func send(_ urls: [URL]) {
        guard allowSend else { return log("not sending: this session doesn't allow files to the viewer") }
        log("sending \(urls.map(\.lastPathComponent))")
        lastSentNames = urls.map(\.lastPathComponent)
        engine.sendItems(urls)
    }

    func stop() { engine.stop() }

    /// The viewer asked for the files copied in Finder.
    func pull() {
        guard allowSend else {
            engine.send(.pullResult(status: FileStatus.declined, detail: "This session doesn't allow files to the viewer"), false)
            return
        }
        DispatchQueue.main.async { [self] in
            let pb = NSPasteboard.general
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if urls.isEmpty {
                log("pull: no files on the pasteboard")
                engine.send(.pullResult(status: FileStatus.nothing, detail: "No files on the Mac clipboard — copy them in Finder first"), false)
                return
            }
            log("pull: sending \(urls.count) copied item(s)")
            engine.send(.pullResult(status: FileStatus.ok, detail: ""), false)
            lastSentNames = urls.map(\.lastPathComponent)
            engine.sendItems(urls)
        }
    }

    private func on(_ e: FileTransferEngine.Event) {
        switch e {
        case let .started(incoming, files, bytes):
            log("\(incoming ? "receiving" : "sending") \(FileOffers.fileText(files)) (\(FileOffers.byteText(bytes)))")
        case let .received(files, bytes, dir, items):
            log("received \(FileOffers.fileText(files)) (\(FileOffers.byteText(bytes))) into \(dir.path): \(items.map(\.lastPathComponent))")
            HostStatus.shared.addTransfer(.init(incoming: true, files: files, bytes: bytes, items: items, ok: true, text: nil, date: Date()))
            HostNotifier.shared.received(files: files, bytes: bytes, items: items, from: viewerName)
            onAudit?(false, files, bytes, items.map(\.lastPathComponent))
        case let .sent(files, bytes):
            log("viewer saved \(FileOffers.fileText(files)) (\(FileOffers.byteText(bytes)))")
            HostStatus.shared.addTransfer(.init(incoming: false, files: files, bytes: bytes, items: [], ok: true, text: nil, date: Date()))
            onAudit?(true, files, bytes, lastSentNames)
        case let .failed(why):
            log(why)
            HostStatus.shared.addTransfer(.init(incoming: false, files: 0, bytes: 0, items: [], ok: false, text: why, date: Date()))
        case let .info(m): log(m)
        }
        HostStatus.shared.update { _ in }  // refresh the menu
    }
}

/// macOS notifications for received files ("Received 3 files — Show in Finder"). Only works from
/// the app bundle (the LaunchAgent); a bare binary has no bundle identifier and skips them. The
/// menu bar's "Recent Transfers" submenu is always available as the fallback.
final class HostNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = HostNotifier()
    static let category = "glide.files.received"
    static let revealAction = "reveal"
    private var ready = false

    /// UNUserNotificationCenter raises if the process has no app bundle.
    var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Main thread, at launch (so a click on a notification is delivered to us).
    func setUp() {
        guard available, !ready else { return }
        ready = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder", options: [.foreground])
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reveal], intentIdentifiers: [])])
    }

    func received(files: Int, bytes: UInt64, items: [URL], from viewer: String) {
        guard available else { return }
        DispatchQueue.main.async { [self] in
            setUp()
            let c = UNUserNotificationCenter.current()
            c.requestAuthorization(options: [.alert, .sound]) { granted, err in
                guard granted else {
                    log("files: notifications not allowed (\(err?.localizedDescription ?? "denied in System Settings > Notifications")); see the menu bar's Recent Transfers")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "Received \(FileOffers.fileText(files))"
                let names = items.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (items.count > 3 ? ", …" : "")
                content.body = "\(names) (\(FileOffers.byteText(bytes))) from \(viewer) — click to show in Finder"
                content.categoryIdentifier = Self.category
                content.userInfo = ["paths": items.map(\.path)]
                c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
                    if let err { log("files: notification failed: \(err.localizedDescription)") }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            DispatchQueue.main.async { Self.reveal(paths.map { URL(fileURLWithPath: $0) }) }
        }
        completionHandler()
    }

    /// Select the items in Finder (never opens them).
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}

/// The host's global `log` (Encoder.swift), reachable from types that define their own `log`.
private func glideFilesLog(_ s: String) { log(s) }
