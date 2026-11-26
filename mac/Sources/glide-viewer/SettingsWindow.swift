import AppKit
import GlideCore

/// Glide Viewer → Settings… (⌘,): the per-viewer preferences in viewer.json (`remapModifiers`,
/// `startFullScreen`), the session shortcuts (read-only), and this Mac's viewer key fingerprint. Changes are saved at once.
final class SettingsController: NSObject {
    let window: NSWindow
    private let remap = NSButton(checkboxWithTitle: "Map Mac modifier keys to PC keys", target: nil, action: nil)
    private let remapNote = NSTextField(wrappingLabelWithString: "")
    private let fullScreen = NSButton(checkboxWithTitle: "Open sessions in full screen", target: nil, action: nil)
    private let fullScreenNote = NSTextField(wrappingLabelWithString: "")
    private let fingerprint: String
    /// Glide Cloud (ENTERPRISE.md): organization, signed-in user, Sign In / Sign Out.
    private let orgTitle = NSTextField(labelWithString: "Organization")
    private let orgStatus = NSTextField(wrappingLabelWithString: "")
    private let orgButton = NSButton(title: "Sign In…", target: nil, action: nil)
    /// "Sign In…" was clicked (the app shows the sign-in window).
    var onSignIn: (() -> Void)?
    /// Command-line flags that override the saved settings for this run.
    private let noRemapFlag: Bool
    private let fullscreenFlag: Bool
    /// The saved settings changed (the app applies the remap to a running session).
    var onChange: ((ViewerConfig) -> Void)?

    init(fingerprint: String, noRemapFlag: Bool, fullscreenFlag: Bool) {
        self.fingerprint = fingerprint
        self.noRemapFlag = noRemapFlag
        self.fullscreenFlag = fullscreenFlag
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Glide Viewer Settings"
        window.isReleasedWhenClosed = false
        super.init()

        remap.target = self
        remap.action = #selector(remapChanged(_:))
        fullScreen.target = self
        fullScreen.action = #selector(fullScreenChanged(_:))
        for n in [remapNote, fullScreenNote] { styleNote(n) }

        let keyTitle = NSTextField(labelWithString: "This Mac's viewer key")
        keyTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let keyField = NSTextField(labelWithString: fingerprint)
        keyField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        keyField.isSelectable = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyFingerprint(_:)))
        let keyRow = NSStackView(views: [keyField, copy])
        keyRow.spacing = 8
        let keyNote = NSTextField(wrappingLabelWithString: "")
        styleNote(keyNote)
        keyNote.stringValue = "The PC shows this fingerprint in its pairing dialog: compare it there. The key itself is kept in viewer-key next to viewer.json."

        let keyboardTitle = NSTextField(labelWithString: "Keyboard")
        keyboardTitle.font = keyTitle.font
        let windowTitle = NSTextField(labelWithString: "Sessions")
        windowTitle.font = keyTitle.font

        let shortcutsTitle = NSTextField(labelWithString: "Session shortcuts")
        shortcutsTitle.font = keyTitle.font
        let grid = NSGridView(views: ViewerShortcut.allCases.map { s -> [NSView] in
            let k = NSTextField(labelWithString: ShortcutBindings.label(s))
            k.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let d = NSTextField(wrappingLabelWithString: s.help)
            d.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            d.preferredMaxLayoutWidth = 320
            return [k, d]
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        let shortcutsNote = NSTextField(wrappingLabelWithString: "Control + Option + Shift + key, on this Mac's keys whatever the modifier mapping. They are never sent to the PC, also in full screen; the Connection and View menus show them too.")
        styleNote(shortcutsNote)

        let showFile = NSButton(title: "Show viewer.json in Finder", target: self, action: #selector(showFile(_:)))
        showFile.bezelStyle = .inline
        showFile.controlSize = .small

        orgTitle.font = keyTitle.font
        orgButton.target = self
        orgButton.action = #selector(orgClicked(_:))
        let orgRow = NSStackView(views: [orgStatus, orgButton])
        orgRow.spacing = 8
        orgRow.alignment = .top
        let stack = NSStackView(views: [orgTitle, orgRow, keyboardTitle, remap, remapNote, windowTitle, fullScreen, fullScreenNote, shortcutsTitle, grid, shortcutsNote, keyTitle, keyRow, keyNote, showFile])
        stack.setCustomSpacing(16, after: orgRow)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: remapNote)
        stack.setCustomSpacing(16, after: fullScreenNote)
        stack.setCustomSpacing(16, after: shortcutsNote)
        stack.setCustomSpacing(16, after: keyNote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 440),
            remapNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            fullScreenNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            shortcutsNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            keyNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            orgRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        NotificationCenter.default.addObserver(forName: ManagedViewer.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshOrg() }
        window.contentView = content
    }

    private func styleNote(_ n: NSTextField) {
        n.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        n.textColor = .secondaryLabelColor
    }

    func show() {
        refresh()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshOrg() {
        let mv = ManagedViewer.shared
        orgTitle.isHidden = !mv.isManaged
        orgStatus.superview?.isHidden = !mv.isManaged
        guard mv.isManaged else { return }
        var lines = [mv.status?.summary ?? "Managed"]
        if let u = mv.user { lines.append("Signed in as \(u.label)") } else if mv.isEnrolled { lines.append("Not signed in") }
        if let d = mv.status?.deviceName { lines.append("This Mac: \(d)") }
        if let why = mv.lanBlockedReason { lines.append("LAN connections are \(why).") }
        if mv.policy.updateRequired { lines.append("Update required: \(mv.orgName) requires \(mv.policy.minAppVersion ?? "?") or later.") }
        orgStatus.stringValue = lines.joined(separator: "\n")
        orgButton.title = mv.isSignedIn ? "Sign Out" : "Sign In…"
        orgButton.isEnabled = mv.isEnrolled
    }

    @objc private func orgClicked(_ sender: Any?) {
        if ManagedViewer.shared.isSignedIn { ManagedViewer.shared.signOut() } else { onSignIn?() }
    }

    private func refresh() {
        refreshOrg()
        let c: ViewerConfig
        do { c = try ViewerStore.load() } catch {
            remap.isEnabled = false
            fullScreen.isEnabled = false
            remapNote.stringValue = "Can't read viewer.json (\(error)). Fix or move the file; settings can't be changed until then."
            return
        }
        remap.isEnabled = true
        fullScreen.isEnabled = true
        remap.state = c.remapModifiers ? .on : .off
        fullScreen.state = c.startFullScreen ? .on : .off
        var r = "Command → Control, Control → Windows, Option → Alt, so ⌘C, ⌘V and ⌘Z do what they do on the Mac. Off: keys are sent as they are (Command → Windows)."
        if noRemapFlag { r += "\nThis run was started with --no-remap, which turns mapping off until you relaunch." }
        remapNote.stringValue = r
        var f = "New session windows open in full screen. Leave or enter it with \(ShortcutBindings.label(.toggleFullScreen))."
        if fullscreenFlag { f += "\nThis run was started with --fullscreen." }
        fullScreenNote.stringValue = f
    }

    private func save(_ change: @escaping (inout ViewerConfig) -> Void) {
        var saved: ViewerConfig?
        let err = ViewerStore.update({ c in change(&c); saved = c })
        // `update` runs the closure before writing: a failed write must not reach the session.
        if err != nil { saved = nil }
        if let err {
            let a = NSAlert()
            a.messageText = "Can't save viewer.json"
            a.informativeText = "\(err)"
            a.alertStyle = .warning
            a.beginSheetModal(for: window, completionHandler: nil)
        }
        refresh()
        if let saved { onChange?(saved) }
    }

    @objc private func remapChanged(_ sender: NSButton) {
        let on = sender.state == .on
        save { $0.remapModifiers = on }
    }

    @objc private func fullScreenChanged(_ sender: NSButton) {
        let on = sender.state == .on
        save { $0.startFullScreen = on }
    }

    @objc private func copyFingerprint(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fingerprint, forType: .string)
    }

    @objc private func showFile(_ sender: Any?) {
        let url = ViewerPaths.config
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
