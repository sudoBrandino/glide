import AppKit
import CryptoKit
import Foundation
import GlideCore

// glide-viewer: control a Windows PC running glide-host.exe from this Mac (docs/WINDOWS_HOST.md).
// The Mac is the viewer: Noise initiator, writes first (docs/PROTOCOL.md §0–3).
//
// Usage:
//   glide-viewer                      the Connections window (never connects on its own)
//   glide-viewer NAME|HOST[:PORT]     connect (a saved connection's name, or an address; port 7421)
//     --pair                          ask to pair even if the host key is already pinned
//     --no-remap                      send Command/Control/Option as they are (default: Command ->
//                                     Control, Control -> Windows, Option -> Alt)
//     --fullscreen                    start in full screen (Settings can make it the default)
//   glide-viewer --forget HOST[:PORT] remove the pinned host key (unpair on this Mac)
//
// Files: ~/Library/Application Support/Glide/viewer.json (connections, pinnedHosts,
// remapModifiers, startFullScreen) and viewer-key (this Mac's identity, 64 hex chars, mode 0600).
// First connection to a PC: open "Pair New Mac…" on the PC, then compare the 6-digit code shown
// on both screens. With Accessibility permission, system shortcuts (⌘Tab, ⌘Space) go to the PC
// while the viewer window is focused.
// Session shortcuts are never sent to the PC: ⌃⌥⇧Q disconnect, ⌃⌥⇧F full screen, ⌃⌥⇧K release
// the keyboard, ⌃⌥⇧D reconnect, ⌃⌥⇧Space session menu (docs/WINDOWS_HOST.md).

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
// Managed mode (docs/ENTERPRISE.md): enrollment and sign-in from the managed settings.
ManagedViewer.shared.prepare(identity: identity)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let options: Options
    let identity: Curve25519.KeyAgreement.PrivateKey
    private var list: ConnectionListController?
    private var settings: SettingsController?
    private var session: ViewerSession?
    private var signIn: SignInController?

    init(options: Options, identity: Curve25519.KeyAgreement.PrivateKey) {
        self.options = options
        self.identity = identity
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Only a target on the command line connects at launch. With no arguments the
        // Connections window opens and nothing is dialed until the user picks a connection.
        if let t = options.target {
            let cfg = (try? ViewerStore.load()) ?? ViewerConfig()
            guard let r = cfg.resolve(t) else {
                print("not a saved connection or HOST[:PORT]: \(t)")
                exit(2)
            }
            if let why = ManagedViewer.shared.lanBlockedReason {
                print("LAN connections are \(why); not connecting to \(t)")
                showList()
                return
            }
            let name = cfg.connections.first { $0.id == r.connectionID }?.name
            open(target: r.target, connectionID: r.connectionID, label: (name?.isEmpty == false ? name : nil) ?? r.target.display, config: cfg)
        } else {
            showList()
        }
    }

    private func connectionList() -> ConnectionListController {
        if let list { return list }
        let l = ConnectionListController()
        l.onConnect = { [weak self] c in
            guard let self, let t = c.target else { return }
            self.list?.window.orderOut(nil)
            let cfg = (try? ViewerStore.load()) ?? ViewerConfig()
            self.open(target: t, connectionID: c.id, label: c.name.isEmpty ? t.display : c.name, config: cfg)
        }
        l.onConnectCloud = { [weak self] host, viewOnly in
            guard let self else { return }
            self.list?.window.orderOut(nil)
            self.openCloud(host, viewOnly: viewOnly)
        }
        l.onSignIn = { [weak self] in self?.showSignIn(nil) }
        list = l
        return l
    }

    /// A managed session with one of the organization's hosts (ENTERPRISE.md §5.3).
    private func openCloud(_ host: CloudHost, viewOnly: Bool) {
        session?.close()
        let cfg = (try? ViewerStore.load()) ?? ViewerConfig()
        let target = ViewerTarget(host: "relay:" + host.id, port: 0)
        let s = ViewerSession(target: target, connectionID: nil, label: PairedViewer.displayName(host.name), identity: identity,
                              remap: cfg.remapModifiers && !options.noRemap, forcePair: false,
                              fullscreen: options.fullscreen || cfg.startFullScreen, cloud: CloudConnector(host: host, viewOnly: viewOnly))
        s.onEnd = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            self.showList()
        }
        session = s
        s.start()
    }

    @objc private func showSignIn(_ sender: Any?) {
        if let s = signIn { s.window.makeKeyAndOrderFront(nil); return }
        let s = SignInController()
        s.onClose = { [weak self] in self?.signIn = nil }
        signIn = s
        s.start()
    }

    @objc private func signOut(_ sender: Any?) { ManagedViewer.shared.signOut() }

    private func showList() { connectionList().show() }

    private func open(target: ViewerTarget, connectionID: String?, label: String, config: ViewerConfig) {
        session?.close()
        let s = ViewerSession(target: target, connectionID: connectionID, label: label, identity: identity,
                              remap: config.remapModifiers && !options.noRemap, forcePair: options.pair,
                              fullscreen: options.fullscreen || config.startFullScreen)
        s.onEnd = { [weak self, weak s] in
            // A session replaced from the connection list ends after its successor started:
            // only the current session may clear it and show the list. Closing the session
            // window (Disconnect) always returns to the Connections window, also for a session
            // started from the command line; Quit is ⌘Q.
            guard let self, let s, self.session === s else { return }
            self.session = nil
            self.showList()
        }
        s.sessionMenu = { [weak self] in self?.makeSessionMenu() }
        session = s
        s.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && session == nil { showList() }
        return true
    }

    // MARK: Menu actions

    @objc private func showConnections(_ sender: Any?) { showList() }

    @objc private func newConnection(_ sender: Any?) {
        let l = connectionList()
        l.show()
        l.addClicked(sender)
    }

    @objc private func disconnect(_ sender: Any?) {
        // Closes the session window; its onEnd shows the Connections window.
        session?.close()
    }

    @objc private func reconnect(_ sender: Any?) { session?.reconnect(sender) }

    @objc private func toggleKeyboard(_ sender: Any?) {
        guard let s = session else { return }
        s.setKeyboardReleased(!s.keyboardReleased)
    }

    @objc private func toggleSessionFullScreen(_ sender: Any?) { session?.toggleFullScreen() }

    @objc private func showSessionMenu(_ sender: Any?) { session?.showSessionMenu() }

    /// ⌃⌥⇧Space: the session's own menu at the pointer (handy in full screen, where the menu bar
    /// hides).
    private func makeSessionMenu() -> NSMenu {
        let m = NSMenu(title: "Glide")
        m.autoenablesItems = true
        shortcutItem(m, "Disconnect", #selector(disconnect(_:)), .disconnect)
        shortcutItem(m, "Reconnect", #selector(reconnect(_:)), .reconnect)
        m.addItem(.separator())
        let fs = session?.window.styleMask.contains(.fullScreen) == true
        shortcutItem(m, fs ? "Exit Full Screen" : "Enter Full Screen", #selector(toggleSessionFullScreen(_:)), .toggleFullScreen)
        shortcutItem(m, "Release Keyboard", #selector(toggleKeyboard(_:)), .releaseKeyboard)
        m.addItem(.separator())
        let c = m.addItem(withTitle: "Connections…", action: #selector(showConnections(_:)), keyEquivalent: "")
        c.target = self
        let st = m.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: "")
        st.target = self
        return m
    }

    /// A menu item whose key equivalent is a session shortcut (⌃⌥⇧+key). In a menu it works while
    /// keys are not being sent to the PC; while they are, KeyCapture takes the same chord first.
    @discardableResult
    private func shortcutItem(_ m: NSMenu, _ title: String, _ action: Selector, _ s: ViewerShortcut) -> NSMenuItem {
        let i = m.addItem(withTitle: title, action: action, keyEquivalent: s.character)
        i.keyEquivalentModifierMask = [.control, .option, .shift]
        i.target = self
        return i
    }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil {
            let s = SettingsController(fingerprint: GlideHandshake.fingerprint(identity.publicKey.rawRepresentation),
                                       noRemapFlag: options.noRemap, fullscreenFlag: options.fullscreen)
            s.onSignIn = { [weak self] in self?.showSignIn(nil) }
            s.onChange = { [weak self] cfg in
                guard let self else { return }
                self.session?.setRemap(cfg.remapModifiers && !self.options.noRemap)
            }
            settings = s
        }
        settings?.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Glide Viewer",
            .applicationVersion: GlideVersion.display,
            .version: "protocol v\(GlideVersion.protocolVersion)",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(disconnect(_:)), #selector(reconnect(_:)), #selector(showSessionMenu(_:)): return session != nil
        case #selector(toggleSessionFullScreen(_:)):
            item.title = session?.window.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return session != nil
        case #selector(toggleKeyboard(_:)):
            item.title = session?.keyboardReleased == true ? "Capture Keyboard" : "Release Keyboard"
            return session?.phase == .streaming
        case #selector(showSignIn(_:)):
            item.isHidden = !ManagedViewer.shared.isManaged || ManagedViewer.shared.isSignedIn
            return ManagedViewer.shared.isEnrolled
        case #selector(signOut(_:)):
            item.isHidden = !ManagedViewer.shared.isSignedIn
            return true
        default: return true
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            main.addItem(item)
            let m = NSMenu(title: title)
            item.submenu = m
            return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
        }

        let app = submenu("Glide Viewer")
        add(app, "About Glide Viewer", #selector(showAbout(_:)), target: self)
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        add(app, "Sign In to Your Organization…", #selector(showSignIn(_:)), target: self)
        add(app, "Sign Out of Your Organization", #selector(signOut(_:)), target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Hide Glide Viewer", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Glide Viewer", #selector(NSApplication.terminate(_:)), "q")

        let conn = submenu("Connection")
        add(conn, "New Connection…", #selector(newConnection(_:)), "n", target: self)
        add(conn, "Connections…", #selector(showConnections(_:)), "0", target: self)
        conn.addItem(.separator())
        // Session shortcuts (⌃⌥⇧+key): never sent to the PC, so they work while streaming too.
        shortcutItem(conn, "Reconnect", #selector(reconnect(_:)), .reconnect)
        shortcutItem(conn, "Disconnect", #selector(disconnect(_:)), .disconnect)
        conn.addItem(.separator())
        shortcutItem(conn, "Release Keyboard", #selector(toggleKeyboard(_:)), .releaseKeyboard)
        shortcutItem(conn, "Session Menu", #selector(showSessionMenu(_:)), .openMenu)

        // Text fields (Add / Edit, search) need these for ⌘C / ⌘V / ⌘A to work.
        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        // NSWindow's own action (nil target): AppKit keeps the title (Enter / Exit) and doesn't
        // add a second full-screen item.
        shortcutItem(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), .toggleFullScreen).target = nil

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        add(window, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options, identity: identity)
app.delegate = delegate
app.run()
