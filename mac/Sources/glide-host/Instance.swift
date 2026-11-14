import AppKit
import Foundation
import GlideCore
import ServiceManagement

/// One Glide Host per user, whichever way it was started (Finder/Launch Services, the login item,
/// the install script's LaunchAgent), plus the pieces the setup window needs to install, start at
/// login and relaunch without Terminal.
///
/// Rules when a host is already running (it answers on the control socket):
/// - Started by launchd (login item / LaunchAgent) and the running one wasn't: ask it to hand off
///   (it quits), then take over. A launchd job must win, or KeepAlive would relaunch it forever.
/// - Opened by hand, same app and version: bring up the running host's setup window and quit.
/// - Opened by hand, another version or location (a new download): run as the installer only
///   (no server), so the setup window can replace the running copy.
enum Instance {
    enum Role: Equatable {
        case primary
        /// Another host is running and will show its window; quit.
        case defer_
        /// Replace the running host (`version` at `path`, nil when it's too old to say).
        case installer(version: String?, path: String?)
    }

    /// The launchd label when started as a login item or LaunchAgent (KeepAlive relaunches us).
    static let launchdLabel: String? = {
        let env = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        return (env?.isEmpty == false && env != "0") ? env : nil
    }()

    static var bundlePath: String { Bundle.main.bundlePath }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.sudobrandino.glide.host" }
    /// True when running from an .app bundle (not a bare `swift build` binary).
    static var isAppBundle: Bool { bundlePath.hasSuffix(".app") }

    // MARK: Role

    static func resolveRole() -> Role {
        guard let c = try? ControlClient(path: PairingController.socketPath) else { return .primary }
        c.send("instance")
        let reply = c.readLine() ?? ""
        c.close()
        // "instance <version> <agent 0|1> <path>"; hosts before 0.3 answer "error unknown command".
        let p = reply.split(separator: " ", maxSplits: 3).map(String.init)
        let theirs: (version: String, agent: Bool, path: String)? =
            p.count == 4 && p[0] == "instance" ? (p[1], p[2] == "1", p[3]) : nil
        if launchdLabel != nil {
            if let t = theirs, !t.agent {
                log("instance: a host opened by hand is running (\(t.path)); asking it to hand over")
                if send("handoff") == "ok handoff", waitUntilGone(seconds: 8) { return .primary }
            }
            // Another launchd job (an old LaunchAgent under another label) or an old host: wait
            // a while before exiting, so KeepAlive doesn't relaunch us every 10 s.
            log("instance: another Glide Host is running (\(theirs?.path ?? "an older version")); exiting in 60 s")
            Thread.sleep(forTimeInterval: 60)
            exit(0)
        }
        if let t = theirs, t.version == GlideVersion.display, t.path == bundlePath { return .defer_ }
        return .installer(version: theirs?.version, path: theirs?.path)
    }

    /// One command to the running host; its first reply line.
    @discardableResult
    static func send(_ line: String) -> String? {
        guard let c = try? ControlClient(path: PairingController.socketPath) else { return nil }
        defer { c.close() }
        c.send(line)
        return c.readLine()
    }

    /// Waits until no host answers on the control socket.
    static func waitUntilGone(seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            guard let c = try? ControlClient(path: PairingController.socketPath) else { return true }
            c.close()
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (try? ControlClient(path: PairingController.socketPath)) == nil
    }

    /// The primary host's answers (PairingController.instanceCommand).
    static func handle(_ line: String, showSetup: @escaping () -> Void, quit: @escaping (String) -> Void) -> String? {
        switch line {
        case "instance":
            return "instance \(GlideVersion.display) \(launchdLabel != nil ? 1 : 0) \(bundlePath)"
        case "show-setup":
            DispatchQueue.main.async(execute: showSetup)
            return "ok"
        case "handoff":
            guard launchdLabel == nil else { return "error this host is the login item" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { quit("handoff to the login item") }
            return "ok handoff"
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { quit("asked to quit (installer)") }
            return "ok quit"
        default:
            return nil
        }
    }

    // MARK: Log

    /// Opened from Finder or as a login item, stderr is /dev/null: log to the usual file instead.
    static func redirectLogIfNeeded() {
        var st = stat(), null = stat()
        guard fstat(2, &st) == 0, stat("/dev/null", &null) == 0, st.st_rdev == null.st_rdev, (st.st_mode & S_IFMT) == S_IFCHR else { return }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fd = open(logs.appendingPathComponent("glide-host.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 { dup2(fd, 2); dup2(fd, 1); close(fd) }
    }

    // MARK: Relaunch

    /// Start again (a new Screen Recording grant only applies to a new process). Under launchd,
    /// exiting is enough (KeepAlive); otherwise reopen the app once this process is gone.
    static func relaunch(reason: String) {
        log("relaunch: \(reason)")
        if launchdLabel == nil {
            spawnDetached("/bin/sh", ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"", bundlePath])
        }
        restoreDisplaysBeforeExit(reason: reason)
        exit(0)
    }

    static func spawnDetached(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    // MARK: Start at login

    enum LoginItem: Equatable {
        case on
        /// The install script's LaunchAgent (~/Library/LaunchAgents) starts this app.
        case onViaScript
        case needsApproval
        case off
    }

    static var loginService: SMAppService { SMAppService.agent(plistName: "\(bundleID).plist") }
    static var scriptAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    static var loginItem: LoginItem {
        switch loginService.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default:
            if FileManager.default.fileExists(atPath: scriptAgentURL.path) { return .onViaScript }
            return .off
        }
    }

    /// Register the bundled LaunchAgent (Contents/Library/LaunchAgents). launchd starts it right
    /// away; that instance takes over from this one (see `resolveRole`).
    static func enableLoginItem() throws {
        try loginService.register()
        log("login item: registered (\(loginService.status.rawValue))")
    }

    static func disableLoginItem() throws {
        try loginService.unregister()
        log("login item: unregistered")
    }

    // MARK: Install / replace

    static var isInApplications: Bool {
        let p = (bundlePath as NSString).deletingLastPathComponent
        return p == "/Applications" || p == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    /// Launch Services runs quarantined downloads from a random read-only copy.
    static var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }

    /// Where Install copies the app: over the running host's copy when it's in an Applications
    /// folder, else /Applications (if writable), else ~/Applications.
    static func installDestination(existing: String?) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if let e = existing, e.hasSuffix(".app"),
           ["/Applications", home.path].contains((e as NSString).deletingLastPathComponent) {
            return URL(fileURLWithPath: e)
        }
        if FileManager.default.isWritableFile(atPath: "/Applications") { return URL(fileURLWithPath: "/Applications/Glide Host.app") }
        return home.appendingPathComponent("Glide Host.app")
    }

    /// Stop every other Glide Host (the running one and the install script's LaunchAgents, which
    /// the login item replaces), copy this app to `dest` and open it from there. Returns an
    /// error text, or never returns.
    /// `stopRunning`: another host is running (installer role); false when this process is the
    /// running host moving itself into Applications.
    static func installAndRelaunch(to dest: URL, stopRunning: Bool) -> String {
        log("install: \(bundlePath) → \(dest.path)")
        // Old LaunchAgents (any *.glide.host label, e.g. an earlier bundle id): stop and remove.
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [] where name.hasSuffix(".glide.host.plist") {
            let label = String(name.dropLast(".plist".count))
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(at: agents.appendingPathComponent(name))
            log("install: removed LaunchAgent \(label)")
        }
        if stopRunning {
            // A login item keeps running the copy at its path; stop it so the copy can be replaced.
            if loginService.status == .enabled { run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(bundleID)"]) }
            send("quit")
            if !waitUntilGone(seconds: 8) {
                // A host too old to take the quit command: stop the other glide-host processes.
                let me = getpid()
                for line in run("/usr/bin/pgrep", ["-f", "Glide Host.app/Contents/MacOS/glide-host"]).output.split(separator: "\n") {
                    if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != me { kill(pid, SIGTERM) }
                }
                _ = waitUntilGone(seconds: 4)
            }
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                if dest.path == bundlePath { return "This copy is already installed." }
                try fm.trashItem(at: dest, resultingItemURL: nil)
            }
            try fm.copyItem(atPath: bundlePath, toPath: dest.path)
        } catch {
            return "Couldn't copy Glide Host to \(dest.deletingLastPathComponent().path): \(error.localizedDescription)"
        }
        // Signed ad hoc and not notarized: Gatekeeper would block the copy while it's quarantined.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        log("install: done; opening \(dest.path)")
        spawnDetached("/bin/sh", ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"", dest.path])
        exit(0)
    }

    // MARK: Network

    /// This Mac's IPv4 addresses on active interfaces (no loopback/link-local), for the PC side.
    static func localAddresses() -> [(address: String, interface: String)] {
        var out: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(i.ifa_flags) & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let a = String(cString: host)
            if a.hasPrefix("169.254.") { continue }
            out.append((a, String(cString: i.ifa_name)))
        }
        return out
    }
}
