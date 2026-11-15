import Foundation
import GlideCore

// Mac host install and config persistence: instance roles, installing over a running host
// (HostInstance, used by glide-host Instance.swift) and host.json read-modify-write (ConfigFile).

/// Every role at launch, and the `instance` reply round trip (the bundle's version has a space).
func instanceRoleTests() {
    print("host instance roles:")
    let me = "/Applications/Glide Host.app", v = "0.3.0 (abc1234)"
    let token = HostInstance.versionToken(v)
    check(!token.contains(" ") && token == "0.3.0+abc1234", "version token has no space (\(token))")
    let r = HostInstance.reply(version: v, agent: true, path: me)
    check(HostInstance.parse(r) == .init(version: token, agent: true, path: me), "instance reply round trip with a commit and a path with spaces")
    check(HostInstance.parse("error unknown command") == nil, "a host before 0.3 parses as unknown")
    check(HostInstance.parse("instance 0.2.0 x /a.app") == nil, "a malformed agent flag is rejected")

    func decide(launchd: Bool = false, _ running: HostInstance.Info?, answered: Bool = true, path: String = me) -> HostInstance.Decision {
        HostInstance.decide(launchd: launchd, answered: answered, running: running, version: v, path: path)
    }
    let same = HostInstance.Info(version: token, agent: false, path: me)
    let old = HostInstance.Info(version: "0.2.0", agent: false, path: me)
    check(decide(nil, answered: false) == .primary, "nothing running -> primary")
    check(decide(same) == .showRunning, "opened by hand, same app running -> show its window")
    check(decide(same, path: me + "/") == .showRunning, "same app, path spelled with a trailing slash")
    check(decide(old) == .installer, "opened by hand, old version at the same path (replaced on disk) -> installer")
    check(decide(.init(version: token, agent: false, path: "/Users/you/Downloads/Glide Host.app")) == .installer, "same version, another copy -> installer")
    check(decide(nil) == .installer, "opened by hand, a host too old to say -> installer")
    check(decide(launchd: true, old) == .askHandoff, "login item, host opened by hand -> ask it to hand over")
    check(decide(launchd: true, .init(version: "0.2.0", agent: true, path: me)) == .waitThenExit, "login item, another launchd job -> wait and exit")
    check(decide(launchd: true, nil) == .waitThenExit, "login item, a host too old to say -> wait and exit")
}

/// Installing over a running host ends with exactly one host: the new version.
func installPlanTests() {
    print("host install / takeover:")
    let app = "/Applications/Glide Host.app", dl = "/Users/you/Downloads/Glide Host.app"
    check(HostInstance.installPlan(destination: app, bundlePath: app, otherHostRunning: true) == .restartInPlace,
          "dragged over the running host's app -> restart in place (no copy, no 'already installed' error)")
    check(HostInstance.installPlan(destination: app, bundlePath: app + "/", otherHostRunning: true) == .restartInPlace, "in place, path normalized")
    check(HostInstance.installPlan(destination: app, bundlePath: app, otherHostRunning: false) == .alreadyInstalled, "in place with nothing else running -> nothing to do")
    check(HostInstance.installPlan(destination: app, bundlePath: dl, otherHostRunning: true) == .copy, "a download -> copy over the running host's app")
    check(HostInstance.installPlan(destination: app, bundlePath: dl, otherHostRunning: false) == .copy, "moving itself into Applications -> copy")

    let id = "io.github.sudobrandino.glide.host"
    check(HostInstance.keepsAgent(label: id, program: app + "/Contents/MacOS/glide-host", bundleID: id, installedApp: app),
          "the script's LaunchAgent for the installed copy is kept (it starts the new version)")
    check(!HostInstance.keepsAgent(label: id, program: "/Users/you/Applications/Glide Host.app/Contents/MacOS/glide-host", bundleID: id, installedApp: app),
          "a LaunchAgent starting another copy is removed")
    check(!HostInstance.keepsAgent(label: "com.example.glide.host", program: app + "/Contents/MacOS/glide-host", bundleID: id, installedApp: app),
          "a LaunchAgent under an earlier bundle id is removed")
    check(!HostInstance.keepsAgent(label: id, program: nil, bundleID: id, installedApp: app), "a LaunchAgent without a program is removed")

    let v = "0.3.0 (abc1234)", token = HostInstance.versionToken(v)
    let old = HostInstance.Seen.host(.init(version: "0.2.0", agent: true, path: app))
    let new = HostInstance.Seen.host(.init(version: token, agent: true, path: app))
    /// Runs the takeover over a timeline of (seconds, what the socket shows); returns the steps
    /// that aren't `wait`, up to the first final one.
    func run(launchd: Bool, oldGone: Bool = false, _ timeline: [(Double, HostInstance.Seen)]) -> [HostInstance.Step] {
        var t = HostInstance.Takeover(version: v, installedPath: app, launchdStartsIt: launchd, oldHostGone: oldGone)
        var out: [HostInstance.Step] = []
        for (at, seen) in timeline {
            let s = t.step(seen, at: at)
            if s != .wait { out.append(s) }
            if s != .wait && s != .forceQuit { break }
        }
        return out
    }
    check(run(launchd: false, [(0, old), (0.25, old), (0.5, .nothing)]) == [.openNew],
          "host opened by hand quits, nothing restarts it -> open this copy")
    check(run(launchd: true, [(0, old), (0.25, .nothing), (1, .nothing), (1.5, new)]) == [.showNew],
          "login item quits, launchd restarts the new binary -> show its window (no second host)")
    check(run(launchd: true, [(0, old), (0.25, .nothing), (7.0, .nothing), (7.5, .nothing)]) == [.openNew],
          "launchd doesn't restart it within the grace -> open this copy (a later launchd start takes over by handoff)")
    check(run(launchd: false, [(0, .host(nil)), (2, .host(nil)), (4, .host(nil)), (4.25, .nothing)]) == [.forceQuit, .openNew],
          "a host too old for 'quit' is terminated, then this copy opens")
    check(run(launchd: false, [(0, old), (4, old), (6, old), (8.5, old)]) == [.forceQuit, .fail],
          "an old host that won't die -> fail (it keeps running, error shown)")
    check(run(launchd: true, [(0, old), (0.25, .nothing), (3, old), (3.25, .nothing), (7.5, .nothing), (8, new)]) == [.showNew],
          "the gone-timer restarts if a host shows up again")
    check(run(launchd: false, [(0, .host(.init(version: token, agent: false, path: "/Users/you/Glide Host.app"))), (4, .host(.init(version: token, agent: false, path: "/Users/you/Glide Host.app")))]) == [.forceQuit],
          "the same version from another path is not the new host")
    check(run(launchd: true, [(0, old), (0.25, .nothing), (4.5, .host(nil)), (4.6, new)]) == [.showNew],
          "a host answering before it can say what it is (after the old one went) is not terminated")
    check(run(launchd: true, [(0, old), (0.25, .nothing), (1, old), (5, old), (9.1, old)]) == [.fail],
          "another host that starts after the old one went -> fail, never terminated (launchd would restart it)")
    check(run(launchd: true, oldGone: true, [(0, .nothing), (2, new)]) == [.showNew],
          "copy install: launchd starts the kept LaunchAgent's new version -> show its window")
    check(run(launchd: false, oldGone: true, [(0, .nothing)]) == [.openNew],
          "copy install, nothing starts it -> open the copy")
    check(run(launchd: true, oldGone: true, [(0, .host(nil)), (5, .host(nil)), (8, .host(nil))]) == [.fail],
          "copy install: an unknown host that stays -> fail, not terminated")
}

/// host.json read-modify-write never replaces a file it can't decode (review finding 2).
func configFileTests() throws {
    print("config file (host.json) read-modify-write:")
    struct Viewer: Codable, Equatable { var name: String }
    struct Config: Codable, Equatable {
        var connect: String?
        var listen: Bool?
        var pairedViewers: [Viewer]?
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-config-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("host.json")

    // The reproduction: "listen" is a string, and a viewer is paired.
    let bad = #"{"listen": "false", "pairedViewers": [{"name": "Gaming PC"}]}"#
    try Data(bad.utf8).write(to: url)
    var threw: ConfigFile.Failure?
    do { try ConfigFile.update(url, defaults: { Config() }) { $0.connect = "192.168.50.9" } } catch let e as ConfigFile.Failure { threw = e }
    check(threw.map { if case .undecodable = $0 { return true } else { return false } } ?? false, "undecodable file -> update throws")
    check(threw?.description.contains("listen") == true, "the error names the bad key (\(threw?.description ?? "-"))")
    check(String(decoding: try Data(contentsOf: url), as: UTF8.self) == bad, "undecodable file left byte for byte (paired viewer kept)")
    check(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path), "no temporary file left behind")

    try Data("not json".utf8).write(to: url)
    check((try? ConfigFile.update(url, defaults: { Config() }) { $0.connect = "x" }) == nil, "invalid JSON -> refused")
    try Data().write(to: url)
    check((try? ConfigFile.update(url, defaults: { Config() }) { $0.connect = "x" }) == nil, "empty file -> refused")

    try FileManager.default.removeItem(at: url)
    check((try ConfigFile.read(Config.self, from: url)) == nil, "missing file reads as nil")
    let created = try ConfigFile.update(url, defaults: { Config() }) { $0.connect = "pc" }
    let reread = try ConfigFile.read(Config.self, from: url)
    check(created == Config(connect: "pc") && reread == created, "missing file -> created from defaults")
    let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "written with mode 0600 (\(String(mode ?? 0, radix: 8)))")

    try Data(#"{"listen": false, "pairedViewers": [{"name": "Gaming PC"}], "futureKey": 1}"#.utf8).write(to: url)
    let changed = try ConfigFile.update(url, defaults: { Config() }) { $0.connect = "192.168.50.9" }
    check(changed == Config(connect: "192.168.50.9", listen: false, pairedViewers: [Viewer(name: "Gaming PC")]),
          "valid file -> only the changed key differs, paired viewers kept")

    let sub = dir.appendingPathComponent("folder.json", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    check((try? ConfigFile.update(sub, defaults: { Config() }) { $0.connect = "x" }) == nil, "a folder in the file's place -> refused")
}
