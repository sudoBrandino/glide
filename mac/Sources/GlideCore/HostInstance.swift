import Foundation

/// The decisions behind "one Glide Host per user" and installing over a running host
/// (glide-host Instance.swift), without side effects so glide-selftest can check every case.
public enum HostInstance {
    /// The launchd job label from `XPC_SERVICE_NAME`, when a login item or LaunchAgent started this
    /// process (launchd's KeepAlive then restarts it after it exits). An app opened from Finder,
    /// the Dock or `open` also has the variable, but as "application.<bundle id>.<n>.<n>" (Launch
    /// Services): that is not a job launchd restarts, so it doesn't count. "0" means none.
    public static func launchdLabel(xpcServiceName: String?) -> String? {
        guard let v = xpcServiceName, !v.isEmpty, v != "0", !v.hasPrefix("application.") else { return nil }
        return v
    }

    /// A running host's answer to `instance` on the control socket.
    public struct Info: Equatable {
        public var version: String
        /// Started by launchd (login item or LaunchAgent).
        public var agent: Bool
        public var path: String
        public init(version: String, agent: Bool, path: String) {
            self.version = version; self.agent = agent; self.path = path
        }
    }

    /// The version as one word: `GlideVersion.display` is "0.3.0 (abc1234)" in an app bundle, and
    /// the reply's fields are separated by spaces.
    public static func versionToken(_ display: String) -> String {
        display.replacingOccurrences(of: " (", with: "+").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "+")
    }

    /// "instance <version> <agent 0|1> <path>" (the path may contain spaces; it comes last).
    public static func reply(version: String, agent: Bool, path: String) -> String {
        "instance \(versionToken(version)) \(agent ? 1 : 0) \(path)"
    }

    /// nil for anything else, e.g. "error unknown command" from hosts before 0.3.
    public static func parse(_ reply: String) -> Info? {
        let p = reply.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, p[0] == "instance", p[2] == "0" || p[2] == "1", !p[3].isEmpty else { return nil }
        return Info(version: p[1], agent: p[2] == "1", path: p[3])
    }

    /// The same app: same version and the same bundle path.
    public static func isSameApp(_ i: Info, version: String, path: String) -> Bool {
        i.version == versionToken(version) && samePath(i.path, path)
    }

    public static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    // MARK: Role at launch

    public enum Decision: Equatable {
        /// No host is running: run the server.
        case primary
        /// Started by launchd while a host opened by hand runs: ask it to hand over, then run.
        case askHandoff
        /// Started by launchd while another launchd job (or a host too old to say) runs: wait,
        /// then exit, so KeepAlive doesn't relaunch every few seconds.
        case waitThenExit
        /// Opened by hand while this same app runs: show its setup window and quit.
        case showRunning
        /// Opened by hand while another version or copy runs: offer to replace it (no server).
        /// When this copy already sits at the running host's path (dragged over it in
        /// Applications), installing just restarts into this version.
        case installer
    }

    /// `answered`: something listens on the control socket; `running`: its parsed reply.
    public static func decide(launchd: Bool, answered: Bool, running: Info?, version: String, path: String) -> Decision {
        guard answered else { return .primary }
        if launchd { return running.map { $0.agent ? .waitThenExit : .askHandoff } ?? .waitThenExit }
        if let r = running, isSameApp(r, version: version, path: path) { return .showRunning }
        return .installer
    }

    // MARK: Install

    public enum InstallPlan: Equatable {
        /// Copy this app to the destination (moving what's there to the Trash), then start it.
        case copy
        /// This copy already is the destination, under a host still running the old version from
        /// the same path (the app was replaced on disk): stop that host and start this version.
        case restartInPlace
        /// This copy is the destination and no other host runs: nothing to do.
        case alreadyInstalled
    }

    public static func installPlan(destination: String, bundlePath: String, otherHostRunning: Bool) -> InstallPlan {
        guard samePath(destination, bundlePath) else { return .copy }
        return otherHostRunning ? .restartInPlace : .alreadyInstalled
    }

    /// The install script's LaunchAgents (~/Library/LaunchAgents/*.glide.host.plist): keep the one
    /// that starts the installed copy under this app's label (it then starts the new version, at
    /// login and whenever the host exits); remove the others once the new copy is in place (an
    /// earlier bundle id, or another copy of the app, would keep starting an old host).
    public static func keepsAgent(label: String, program: String?, bundleID: String, installedApp: String) -> Bool {
        guard label == bundleID, let program else { return false }
        return samePath(program, (installedApp as NSString).appendingPathComponent("Contents/MacOS/glide-host"))
    }

    // MARK: Taking over

    /// What the installer sees on the control socket while the old host goes away.
    public enum Seen: Equatable {
        case nothing
        /// A host answers; nil when it's too old to say what it is.
        case host(Info?)
    }

    public enum Step: Equatable {
        case wait
        /// The old host ignored `quit` (too old to know it): terminate its process.
        case forceQuit
        /// The new version answers from the installed path (launchd started it): show its setup
        /// window and exit.
        case showNew
        /// Nothing runs and launchd isn't going to start the new version: open it.
        case openNew
        /// The old host is still running after being terminated.
        case fail
    }

    /// After the new version is in place and the old host was asked to quit. Feed it what the
    /// control socket shows every fraction of a second; every path ends with exactly one host:
    /// the new one launchd starts (`showNew`), the one this installer opens (`openNew`; a launchd
    /// job that starts later takes over from it with `handoff`), or the old one (`fail`).
    public struct Takeover {
        public let version: String
        public let installedPath: String
        /// A login item or LaunchAgent starts the installed copy (KeepAlive restarts the host after
        /// it quits; launchd waits ThrottleInterval, 5 s, between starts).
        public let launchdStartsIt: Bool
        public var quitGrace: Double = 4
        public var killGrace: Double = 4
        public var launchdGrace: Double = 7
        private var forcedAt: Double?
        private var goneSince: Double?
        /// The old host has gone (or was stopped before this started).
        private var oldGone: Bool
        private var otherSince: Double?

        /// `oldHostGone`: the old host was already stopped (copy install).
        public init(version: String, installedPath: String, launchdStartsIt: Bool, oldHostGone: Bool = false) {
            self.version = version; self.installedPath = installedPath; self.launchdStartsIt = launchdStartsIt
            oldGone = oldHostGone
        }

        /// `t`: seconds since `quit` was sent.
        public mutating func step(_ seen: Seen, at t: Double) -> Step {
            switch seen {
            case let .host(i?) where HostInstance.isSameApp(i, version: version, path: installedPath):
                return .showNew
            case .host where oldGone:
                // Started after the old host went: most likely the new one, which answers on the
                // socket a moment before it can say what it is; else another launchd job. Never
                // terminate it (launchd would only start it again); give up if it stays.
                goneSince = nil
                if otherSince == nil { otherSince = t }
                return t - otherSince! >= quitGrace + killGrace ? .fail : .wait
            case .host:
                if let f = forcedAt { return t - f >= killGrace ? .fail : .wait }
                if t >= quitGrace { forcedAt = t; return .forceQuit }
                return .wait
            case .nothing:
                oldGone = true
                otherSince = nil
                guard launchdStartsIt else { return .openNew }
                if goneSince == nil { goneSince = t }
                return t - goneSince! >= launchdGrace ? .openNew : .wait
            }
        }
    }
}
