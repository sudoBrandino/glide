import Foundation
import GlideCore

/// `glide-host --pair | --pair-code N | --paired | --unpair X | --identity`: headless pairing and
/// viewer management. Talks to the running host (the LaunchAgent) over its control socket;
/// `--paired`/`--unpair` fall back to editing host.json when no host is running.
func runTrustCommand(_ args: inout [String]) -> Never {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else { print("\(flag) needs a value"); exit(2) }
        return args[i + 1]
    }
    let path = PairingController.socketPath
    func connect() -> ControlClient? { try? ControlClient(path: path) }
    func notRunning() -> Never {
        print("""
        Glide Host isn't running (no control socket at \(path)).
        Start it (it runs as a LaunchAgent; tools/install-host.sh installs and starts it),
        or use the Glide menu-bar item → Pair New Viewer….
        """)
        exit(1)
    }

    if args.contains("--identity") {
        do {
            let k = try HostIdentity.loadOrCreate()
            print("This Mac's Glide key: \(GlideHandshake.fingerprint(k.publicKey.rawRepresentation))")
            print("(public key \(k.publicKey.rawRepresentation.hex); the viewer shows the fingerprint while pairing)")
            exit(0)
        } catch { print("\(error.localizedDescription)"); exit(1) }
    }

    if args.contains("--paired") {
        var rows: [PairedViewer] = []
        if let c = connect() {
            c.send("list")
            while let l = c.readLine(), l != "end" {
                let p = l.split(separator: " ", maxSplits: 3).map(String.init)
                guard p.count == 4, p[0] == "viewer" else { continue }
                var v = PairedViewer(name: p[3], key: Data(hex: p[1]) ?? Data(), paired: Date())
                v.paired = p[2]
                rows.append(v)
            }
        } else {
            rows = HostConfig.load().pairedViewers ?? []
        }
        if rows.isEmpty { print("No paired viewers. Pair one with: glide-host --pair") }
        for v in rows { print("\(v.name)\tkey \(v.fingerprint)\tpaired \(v.paired)") }
        exit(0)
    }

    if let q = value("--unpair") {
        if let c = connect() {
            c.send("unpair \(q)")
            let r = c.readLine() ?? "error host closed the connection"
            print(r.hasPrefix("ok ") ? String(r.dropFirst(3)) : r)
            exit(r.hasPrefix("ok") ? 0 : 1)
        }
        var gone: [PairedViewer] = []
        let needle = q.lowercased().replacingOccurrences(of: " ", with: "")
        HostConfig.modify { c in
            let all = c.pairedViewers ?? []
            gone = all.filter { $0.name == q || (needle.count >= 8 && ($0.key.hasPrefix(needle) || $0.fingerprint.replacingOccurrences(of: " ", with: "").hasPrefix(needle))) }
            c.pairedViewers = all.filter { !gone.contains($0) }
        }
        print(gone.isEmpty ? "no paired viewer matches \(q)" : "removed \(gone.map(\.name).joined(separator: ", ")) (host not running; edited host.json)")
        exit(gone.isEmpty ? 1 : 0)
    }

    if let code = value("--pair-code") {
        guard let c = connect() else { notRunning() }
        c.send("code \(code)")
        let r = c.readLine() ?? "error host closed the connection"
        print(r)
        exit(r.hasPrefix("ok") ? 0 : 1)
    }

    // --pair
    guard let c = connect() else { notRunning() }
    c.send("open")
    guard let opened = c.readLine(), opened.hasPrefix("ok open") else { print("could not open the pairing window"); exit(1) }
    let secs = opened.split(separator: " ").last.map(String.init) ?? "120"
    print("Pairing window open for \(secs) s. Connect the viewer now (it retries by itself); it will show a 6-digit code.")
    guard isatty(STDIN_FILENO) == 1 else {
        print("When the PC shows the code, confirm it here with:  glide-host --pair-code NNNNNN")
        print("(or click “Codes Match — Pair” in the alert on the Mac's screen)")
        exit(0)
    }
    c.send("wait")
    while let line = c.readLine() {
        let p = line.split(separator: " ", maxSplits: 3).map(String.init)
        switch p.first {
        case "code" where p.count == 4:
            print("\nViewer “\(p[3])” wants to pair (viewer key \(p[2])).")
            print("Type the 6-digit code shown on the PC (Enter alone declines): ", terminator: "")
            fflush(stdout)
            let typed = readLine() ?? ""
            c.send("code \(typed.isEmpty ? "decline" : typed)")
        case "ok", "error":
            print(line.hasPrefix("ok ") ? String(line.dropFirst(3)) : line)
        case "done":
            let rest = p.dropFirst().joined(separator: " ")
            if rest.hasPrefix("paired") { print("Paired: \(rest.dropFirst(7)). The viewer connects now."); exit(0) }
            if rest == "closed" { print("Pairing window closed."); exit(1) }
            print("Pairing \(rest)."); exit(1)
        default:
            break
        }
    }
    print("host closed the control connection")
    exit(1)
}
