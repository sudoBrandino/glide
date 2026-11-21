import AppKit
import GlideCore

/// Glide Viewer → Settings… (⌘,): the per-viewer preferences in viewer.json (`remapModifiers`,
/// `startFullScreen`) and this Mac's viewer key fingerprint. Changes are saved at once.
final class SettingsController: NSObject {
    let window: NSWindow
    private let remap = NSButton(checkboxWithTitle: "Map Mac modifier keys to PC keys", target: nil, action: nil)
    private let remapNote = NSTextField(wrappingLabelWithString: "")
    private let fullScreen = NSButton(checkboxWithTitle: "Open sessions in full screen", target: nil, action: nil)
    private let fullScreenNote = NSTextField(wrappingLabelWithString: "")
    private let fingerprint: String
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

        let showFile = NSButton(title: "Show viewer.json in Finder", target: self, action: #selector(showFile(_:)))
        showFile.bezelStyle = .inline
        showFile.controlSize = .small

        let stack = NSStackView(views: [keyboardTitle, remap, remapNote, windowTitle, fullScreen, fullScreenNote, keyTitle, keyRow, keyNote, showFile])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: remapNote)
        stack.setCustomSpacing(16, after: fullScreenNote)
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
            keyNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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

    private func refresh() {
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
        var f = "New session windows open in full screen. Leave full screen with View → Exit Full Screen."
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
