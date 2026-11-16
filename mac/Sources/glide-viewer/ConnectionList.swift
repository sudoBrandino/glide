import AppKit
import GlideCore

/// The minimal saved-connections window (glide-viewer with no arguments): viewer.json
/// `connections`, with Connect / Add / Remove. All state lives in `ViewerConfig`; this is only a
/// view of it (a fuller connection manager can replace it without touching the model).
final class ConnectionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private var connections: [SavedConnection] = []
    /// The user picked a connection.
    var onConnect: ((SavedConnection) -> Void)?

    override init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Glide Viewer"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 320, height: 200)
        window = w
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.title = "Saved connections"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 36
        table.target = self
        table.doubleAction = #selector(connectClicked(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let connect = NSButton(title: "Connect", target: self, action: #selector(connectClicked(_:)))
        connect.keyEquivalent = "\r"
        let add = NSButton(title: "Add…", target: self, action: #selector(addClicked(_:)))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeClicked(_:)))
        let buttons = NSStackView(views: [add, remove, NSView(), connect])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        w.contentView = content
        reload()
    }

    func show() {
        reload()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        do {
            connections = try ViewerStore.load().connections
        } catch {
            connections = []
            showError("Can't read viewer.json", "\(error)")
        }
        table.reloadData()
        if !connections.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < connections.count else { return nil }
        let c = connections[row]
        let text = NSTextField(labelWithString: "")
        let title = NSMutableAttributedString(string: c.name.isEmpty ? c.address : c.name,
                                              attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        var detail = "  \(c.address)"
        if let g = c.group, !g.isEmpty { detail += " · \(g)" }
        if c.favorite { detail += " · ★" }
        title.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        text.attributedStringValue = title
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    // MARK: Actions

    @objc private func connectClicked(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        onConnect?(connections[row])
    }

    @objc private func addClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add a connection"
        alert.informativeText = "The PC's address (HOST or HOST:PORT; port \(ViewerTarget.defaultPort) if omitted)."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        name.placeholderString = "Name (e.g. Gaming PC)"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        address.placeholderString = "Address (e.g. 192.168.1.20)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        box.addSubview(name)
        box.addSubview(address)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let addr = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard let t = ViewerTarget.parse(addr) else {
            showError("Invalid address", "“\(addr)” is not HOST or HOST:PORT.")
            return
        }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        ViewerStore.update { $0.add(name: n.isEmpty ? t.host : n, address: addr) }
        reload()
        table.selectRowIndexes(IndexSet(integer: max(0, connections.count - 1)), byExtendingSelection: false)
    }

    @objc private func removeClicked(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        let c = connections[row]
        let alert = NSAlert()
        alert.messageText = "Remove “\(c.name)”?"
        alert.informativeText = "Its pinned host key is kept; use glide-viewer --forget \(c.address) to unpair."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = c.id
        ViewerStore.update { $0.remove(id: id) }
        reload()
    }

    private func showError(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }
}
