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
///   (no server), so the setup window can replace the running copy. When this copy already sits
///   where the running host's app is (dragged over it in Applications), installing restarts into
///   this version instead of copying (`installAndRelaunch`).
/// The decisions themselves are in GlideCore (HostInstance), where glide-selftest checks them.
enum Instance {
    enum Role: Equatable {
        case primary
        /// Another host is running and will show its window; quit.
        case defer_
        /// Replace the running host (`version` at `path`, nil when it's too old to say).
        case installer(version: String?, path: String?)
    }

    /// The launchd label when started as a login item or LaunchAgent (KeepAlive relaunches us).
    static let launchdLabel: String? = HostInstance.launchdLabel(xpcServiceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"])

    static var bundlePath: String { Bundle.main.bundlePath }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.sudobrandino.glide.host" }
    /// True when running from an .app bundle (not a bare `swift build` binary).
    static var isAppBundle: Bool { bundlePath.hasSuffix(".app") }

    // MARK: Role

    /// Asks whoever listens on the control socket what it is. `answered` false: no host runs.
    static func queryRunning() -> (answered: Bool, info: HostInstance.Info?) {
        guard let c = try? ControlClient(path: PairingController.socketPath) else { return (false, nil) }
        c.send("instance")
        let reply = c.readLine() ?? ""
        c.close()
        return (true, HostInstance.parse(reply))
    }

    static func resolveRole() -> Role {
        let (answered, theirs) = queryRunning()
        switch HostInstance.decide(launchd: launchdLabel != nil, answered: answered, running: theirs,
                                   version: GlideVersion.display, path: bundlePath) {
        case .primary:
            return .primary
        case .askHandoff:
            log("instance: a host opened by hand is running (\(theirs?.path ?? "?")); asking it to hand over")
            if send("handoff") == "ok handoff", waitUntilGone(seconds: 8) { return .primary }
            fallthrough
        case .waitThenExit:
            // Another launchd job (an old LaunchAgent under another label) or an old host: wait
            // a while before exiting, so KeepAlive doesn't relaunch us every few seconds.
            log("instance: another Glide Host is running (\(theirs?.path ?? "an older version")); exiting in 60 s")
            Thread.sleep(forTimeInterval: 60)
            exit(0)
        case .showRunning:
            return .defer_
        case .installer:
            return .installer(version: theirs?.version, path: theirs?.path)
        }
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
            return HostInstance.reply(version: GlideVersion.display, agent: launchdLabel != nil, path: bundlePath)
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

    /// True when Install would put this app where it already is: it was dragged over the running
    /// host's app (in Applications), so installing means restarting into this version.
    static func installsInPlace(existing: String?) -> Bool {
        HostInstance.samePath(installDestination(existing: existing).path, bundlePath)
    }

    /// Put this version in place at `dest` and leave exactly one host running: this version, at
    /// `dest`. Returns an error text (with the previous host running again), or never returns.
    /// `stopRunning`: another host is running (installer role); false when this process is the
    /// running host moving itself into Applications. `runningPath`: the running host's app.
    ///
    /// - `dest` is this copy (it replaced the running host's app on disk): ask the old host to quit;
    ///   whatever starts it (the login item, the install script's LaunchAgent) now starts this
    ///   version, else this copy opens itself.
    /// - Otherwise stop the running host and anything launchd would restart it with, move the old
    ///   app to the Trash, copy this one there and start it. A failed copy puts the old app back
    ///   and starts it again.
    /// The install script's LaunchAgents are only removed once the new version is in place; the
    /// one that starts the installed copy under this app's label is kept (it now starts this
    /// version at login).
    static func installAndRelaunch(to dest: URL, stopRunning: Bool, runningPath: String?) -> String {
        let plan = HostInstance.installPlan(destination: dest.path, bundlePath: bundlePath, otherHostRunning: stopRunning)
        log("install: \(bundlePath) → \(dest.path) (\(plan))")
        let agents = scriptAgents()
        let keep = agents.filter { HostInstance.keepsAgent(label: $0.label, program: $0.program, bundleID: bundleID, installedApp: dest.path) }
        let stale = agents.filter { a in !keep.contains(a) }
        // This process's own job (a LaunchAgent started us): booting it out now would end us.
        let notMine = { (a: ScriptAgent) in a.label != launchdLabel }

        switch plan {
        case .alreadyInstalled:
            return "This copy is already installed."

        case .restartInPlace:
            // LaunchAgents that start another copy would bring an old host back: stop them first.
            let stopped = stale.filter(notMine).filter { bootout($0) }
            let launchdStartsIt = isLoaded(bundleID)
            log("install: in place; asking the running host to quit (\(launchdStartsIt ? "launchd restarts this version" : "then opening this copy"))")
            send("quit")
            let outcome = waitForTakeover(installed: dest, launchdStartsIt: launchdStartsIt)
            if outcome == .oldStillRunning {
                stopped.forEach { bootstrap($0) }
                return "The running Glide Host didn't quit. Quit it from its menu (or log out and back in), then open this copy again."
            }
            removeAgents(stale)
            finishInstall(dest, outcome, isHost: false)

        case .copy:
            let fm = FileManager.default
            var stopped: [ScriptAgent] = []
            if stopRunning {
                // A login item or LaunchAgent restarts the host it runs (KeepAlive): stop those
                // first, so nothing runs the old copy while it's replaced.
                if loginService.status == .enabled, isLoaded(bundleID) {
                    run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(bundleID)"])
                }
                stopped = agents.filter(notMine).filter { bootout($0) }
                if !stopOtherHost() {
                    // Still running: leave it be, and its LaunchAgents as they were.
                    stopped.forEach { bootstrap($0) }
                    return "The running Glide Host didn't quit. Quit it from its menu, then try again."
                }
            } else {
                stopped = agents.filter(notMine).filter { bootout($0) }
            }
            let existed = fm.fileExists(atPath: dest.path)
            var trashed: NSURL?
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if existed { try fm.trashItem(at: dest, resultingItemURL: &trashed) }
                try fm.copyItem(atPath: bundlePath, toPath: dest.path)
            } catch {
                // Put the old app back and start what ran before.
                if trashed != nil || (!existed && fm.fileExists(atPath: dest.path)) { try? fm.removeItem(at: dest) }
                if let t = trashed as URL? { try? fm.moveItem(at: t, to: dest) }
                stopped.forEach { bootstrap($0) }
                if stopRunning { reopen(runningPath ?? (existed ? dest.path : nil), if: stopped.isEmpty) }
                log("install: copy failed (\(error.localizedDescription)); previous state restored")
                return "Couldn't copy Glide Host to \(dest.deletingLastPathComponent().path): \(error.localizedDescription)"
            }
            // Signed ad hoc and not notarized: Gatekeeper would block the copy while it's quarantined.
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
            removeAgents(stale.filter(notMine))
            // The kept LaunchAgent starts the installed copy, now this version (RunAtLoad).
            let launchdStartsIt = !keep.filter { bootstrap($0) }.isEmpty
            if !stopRunning {
                // This process is the running host: leave it to launchd, or open the copy once gone.
                finishInstall(dest, launchdStartsIt ? .newRunning : .openNew, isHost: true,
                              thenRemove: stale.filter { !notMine($0) })
            }
            let outcome = waitForTakeover(installed: dest, launchdStartsIt: launchdStartsIt, oldHostGone: true)
            if outcome == .oldStillRunning {
                return "Glide Host \(GlideVersion.display) is installed in \(dest.deletingLastPathComponent().path), but another Glide Host keeps running. Quit it from its menu, then open the new copy."
            }
            finishInstall(dest, outcome, isHost: false)
        }
    }

    enum TakeoverOutcome: Equatable { case newRunning, openNew, oldStillRunning }

    /// Watches the control socket until the new version runs (launchd started it), nothing runs
    /// and nothing will (open it), or the old host won't go (HostInstance.Takeover).
    static func waitForTakeover(installed: URL, launchdStartsIt: Bool, oldHostGone: Bool = false) -> TakeoverOutcome {
        var t = HostInstance.Takeover(version: GlideVersion.display, installedPath: installed.path,
                                      launchdStartsIt: launchdStartsIt, oldHostGone: oldHostGone)
        let start = Date()
        while true {
            let (answered, info) = queryRunning()
            switch t.step(answered ? .host(info) : .nothing, at: Date().timeIntervalSince(start)) {
            case .wait: Thread.sleep(forTimeInterval: 0.25)
            case .forceQuit:
                log("install: the old host didn't quit; terminating it")
                killOtherHosts()
            case .showNew: return .newRunning
            case .openNew: return .openNew
            case .fail: return .oldStillRunning
            }
        }
    }

    /// The new version is in place: bring up the setup window of the one launchd started, or
    /// open the installed copy once this process is gone. `isHost`: this process is the running
    /// host (moving itself), so it gives the displays back first. `thenRemove`: this process's
    /// own LaunchAgent, removed last (booting it out ends this process).
    private static func finishInstall(_ dest: URL, _ outcome: TakeoverOutcome, isHost: Bool, thenRemove: [ScriptAgent] = []) -> Never {
        if outcome == .newRunning {
            log("install: done; launchd runs Glide Host \(GlideVersion.display) from \(dest.path)")
            if !isHost { send("show-setup") }
        } else {
            log("install: done; opening \(dest.path)")
            spawnDetached("/bin/sh", ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"", dest.path])
        }
        removeAgents(thenRemove)
        if isHost {
            let stop = { unlink(PairingController.socketPath); restoreDisplaysBeforeExit(reason: "moved to \(dest.path)") }
            if Thread.isMainThread { stop() } else { DispatchQueue.main.sync(execute: stop) }
        }
        exit(0)
    }

    /// Quit the running host (installer role); hosts too old for `quit` are terminated. False if
    /// one still answers.
    private static func stopOtherHost() -> Bool {
        send("quit")
        if waitUntilGone(seconds: 8) { return true }
        killOtherHosts()
        return waitUntilGone(seconds: 4)
    }

    /// SIGTERM to every other glide-host process of a Glide Host app.
    private static func killOtherHosts() {
        let me = getpid()
        for line in run("/usr/bin/pgrep", ["-f", "Glide Host.app/Contents/MacOS/glide-host"]).output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != me { kill(pid, SIGTERM) }
        }
    }

    /// Start the previous host again by hand after a failed install (when no LaunchAgent does).
    private static func reopen(_ path: String?, if condition: Bool) {
        guard condition, let path, FileManager.default.fileExists(atPath: path) else { return }
        log("install: reopening \(path)")
        run("/usr/bin/open", ["-n", path])
    }

    // MARK: The install script's LaunchAgents

    struct ScriptAgent: Equatable {
        let label: String
        let url: URL
        /// The binary it starts (ProgramArguments[0] or Program).
        let program: String?
    }

    /// ~/Library/LaunchAgents/*.glide.host.plist (any label, e.g. an earlier bundle id).
    static func scriptAgents() -> [ScriptAgent] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            .filter { $0.hasSuffix(".glide.host.plist") }
            .map { name in
                let url = dir.appendingPathComponent(name)
                let plist = (try? Data(contentsOf: url)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let program = (plist?["ProgramArguments"] as? [String])?.first ?? plist?["Program"] as? String
                return ScriptAgent(label: plist?["Label"] as? String ?? String(name.dropLast(".plist".count)), url: url, program: program)
            }
    }

    static func isLoaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /// Stops the job (and the host it runs). True if it was loaded.
    static func bootout(_ a: ScriptAgent) -> Bool {
        let ok = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(a.label)"]).status == 0
        if ok { log("install: stopped LaunchAgent \(a.label)") }
        return ok
    }

    /// Loads the job again (RunAtLoad starts its host). True on success.
    @discardableResult
    static func bootstrap(_ a: ScriptAgent) -> Bool {
        let ok = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", a.url.path]).status == 0
        log("install: \(ok ? "started" : "couldn't start") LaunchAgent \(a.label)")
        return ok
    }

    /// Deletes the plists, then stops the jobs (this process's own job last: that ends it).
    private static func removeAgents(_ agents: [ScriptAgent]) {
        for a in agents {
            try? FileManager.default.removeItem(at: a.url)
            log("install: removed LaunchAgent \(a.label)")
        }
        for a in agents where a.label != launchdLabel { _ = bootout(a) }
        for a in agents where a.label == launchdLabel { _ = bootout(a) }
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
