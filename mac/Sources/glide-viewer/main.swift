import AppKit
import CryptoKit
import Foundation
import GlideCore

// glide-viewer: control a Windows PC running glide-host.exe from this Mac (docs/WINDOWS_HOST.md).
// The Mac is the viewer: Noise initiator, writes first (docs/PROTOCOL.md §0–3).
//
// Usage:
//   glide-viewer                      saved connections window (Connect / Add / Remove)
//   glide-viewer NAME|HOST[:PORT]     connect (a saved connection's name, or an address; port 7421)
//     --pair                          ask to pair even if the host key is already pinned
//     --no-remap                      send Command/Control/Option as they are (default: Command ->
//                                     Control, Control -> Windows, Option -> Alt)
//     --fullscreen                    start in full screen
//   glide-viewer --forget HOST[:PORT] remove the pinned host key (unpair on this Mac)
//
// Files: ~/Library/Application Support/Glide/viewer.json (connections, pinnedHosts,
// remapModifiers) and viewer-key (this Mac's identity, 64 hex chars, mode 0600).
// First connection to a PC: open "Pair New Mac…" on the PC, then compare the 6-digit code shown
// on both screens. With Accessibility permission, system shortcuts (⌘Tab, ⌘Space) go to the PC
// while the viewer window is focused.

struct Options {
    var target: String?
    var pair = false
    var noRemap = false
    var fullscreen = false
    var forget: String?
}

func usage() -> Never {
    print("""
    usage: glide-viewer [NAME|HOST[:PORT]] [--pair] [--no-remap] [--fullscreen]
           glide-viewer --forget HOST[:PORT]
    """)
    exit(2)
}

func parseOptions(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--pair": o.pair = true
        case "--no-remap": o.noRemap = true
        case "--fullscreen": o.fullscreen = true
        case "--forget":
            guard i + 1 < argv.count else { usage() }
            i += 1
            o.forget = argv[i]
        case "-h", "--help": usage()
        default:
            // -NSDocumentRevisionsDebugMode etc. from Xcode: ignore AppKit's own arguments.
            if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 2; continue }
            if a.hasPrefix("-") || o.target != nil { print("unexpected argument: \(a)"); usage() }
            o.target = a
        }
        i += 1
    }
    return o
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

let loadedConfig: ViewerConfig
do { loadedConfig = try ViewerStore.load() } catch {
    print("error: \(error)\nFix or move the file (it may hold pinned host keys).")
    exit(1)
}

if let f = options.forget {
    guard let r = loadedConfig.resolve(f) else { print("not a saved connection or HOST[:PORT]: \(f)"); exit(2) }
    var had = false
    if let e = ViewerStore.update({ had = $0.forget(r.target) }) { print("error: \(e)"); exit(1) }
    print(had ? "forgot the host key pinned for \(r.target.pinKey)" : "no host key was pinned for \(r.target.pinKey)")
    exit(0)
}

let identity: Curve25519.KeyAgreement.PrivateKey
do { identity = try ViewerIdentity.loadOrCreate() } catch {
    print("error: \(error)")
    exit(1)
}
print("glide-viewer \(GlideVersion.display), identity \(GlideHandshake.fingerprint(identity.publicKey.rawRepresentation))")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    let identity: Curve25519.KeyAgreement.PrivateKey
    private var list: ConnectionListController?
    private var session: ViewerSession?

    init(options: Options, identity: Curve25519.KeyAgreement.PrivateKey) {
        self.options = options
        self.identity = identity
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if let t = options.target {
            let cfg = (try? ViewerStore.load()) ?? ViewerConfig()
            guard let r = cfg.resolve(t) else {
                print("not a saved connection or HOST[:PORT]: \(t)")
                exit(2)
            }
            let name = cfg.connections.first { $0.id == r.connectionID }?.name
            open(target: r.target, connectionID: r.connectionID, label: (name?.isEmpty == false ? name : nil) ?? r.target.display, config: cfg)
        } else {
            showList()
        }
    }

    private func showList() {
        if list == nil {
            let l = ConnectionListController()
            l.onConnect = { [weak self] c in
                guard let self else { return }
                guard let t = c.target else { return }
                self.list?.window.orderOut(nil)
                let cfg = (try? ViewerStore.load()) ?? ViewerConfig()
                self.open(target: t, connectionID: c.id, label: c.name.isEmpty ? t.display : c.name, config: cfg)
            }
            list = l
        }
        list?.show()
    }

    private func open(target: ViewerTarget, connectionID: String?, label: String, config: ViewerConfig) {
        session?.close()
        let remap = config.remapModifiers && !options.noRemap
        let s = ViewerSession(target: target, connectionID: connectionID, label: label, identity: identity, remap: remap,
                              forcePair: options.pair, fullscreen: options.fullscreen)
        s.onEnd = { [weak self, weak s] in
            guard let self else { return }
            if self.session === s { self.session = nil }
            if self.options.target != nil { NSApp.terminate(nil) } else { self.showList() }
        }
        session = s
        s.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && session == nil { showList() }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glide Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let connItem = NSMenuItem()
        main.addItem(connItem)
        let connMenu = NSMenu(title: "Connection")
        connMenu.addItem(withTitle: "Reconnect", action: #selector(ViewerSession.reconnect(_:)), keyEquivalent: "")
        connMenu.addItem(withTitle: "Saved Connections…", action: #selector(showConnections(_:)), keyEquivalent: "")
        connMenu.addItem(withTitle: "Disconnect", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        connItem.submenu = connMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }

    @objc private func showConnections(_ sender: Any?) { showList() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options, identity: identity)
app.delegate = delegate
app.run()
