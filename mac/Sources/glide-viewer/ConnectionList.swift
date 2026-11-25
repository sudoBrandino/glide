import AppKit
import GlideCore

/// The Connections window (glide-viewer with no arguments, or Connection → Connections…): the
/// saved connections in viewer.json with Connect, Add, Edit, Duplicate, Remove and Unpair, and a
/// search field. It mirrors the Windows viewer's Connections window. All rules (validation, row
/// order, what Remove forgets) live in GlideCore (`ViewerConnections.swift`); this is a view of them.
final class ConnectionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate,
    NSWindowDelegate
{
    /// A line of the table: a group header or a connection.
    private enum Item {
        case header(String)
        case row(ConnectionRow)
        /// Glide Cloud (ENTERPRISE.md): a host the signed-in user may reach.
        case cloud(CloudHost)
        /// Glide Cloud: a line of explanation (not signed in, no hosts, an error).
        case cloudInfo(String)
    }

    let window: NSWindow
    private let table = ConnectionTableView()
    private let search = NSSearchField()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let unpairButton = NSButton(title: "Unpair…", target: nil, action: nil)
    /// "Sign In…" / "Sign Out" for the organization (hidden when not managed).
    private let orgButton = NSButton(title: "Sign In…", target: nil, action: nil)
    private var hostRefresh: Timer?
    private var items: [Item] = []
    private var config = ViewerConfig()
    private var editor: ConnectionEditor?

    /// The user picked a connection (only supported ones are passed).
    var onConnect: ((SavedConnection) -> Void)?
    /// The user picked one of the organization's hosts (`viewOnly`: Connect View Only).
    var onConnectCloud: ((CloudHost, Bool) -> Void)?
    /// "Sign In…" (the app shows the sign-in window).
    var onSignIn: (() -> Void)?

    private enum Column: String, CaseIterable {
        case name, address, status, lastUsed
        var title: String {
            switch self {
            case .name: return "Name"
            case .address: return "Address"
            case .status: return "Pairing"
            case .lastUsed: return "Last Used"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: return 170
            case .address: return 160
            case .status: return 170
            case .lastUsed: return 100
            }
        }
    }

    override init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Connections"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 240)
        w.setFrameAutosaveName("GlideViewerConnections")
        window = w
        super.init()
        w.delegate = self

        for c in Column.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.width = c.width
            col.minWidth = 60
            col.resizingMask = [.autoresizingMask, .userResizingMask]
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(connectClicked(_:))
        table.onDelete = { [weak self] in self?.removeClicked(nil) }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = "Search name, address or group"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add…", target: self, action: #selector(addClicked(_:)))
        for (b, sel) in [(editButton, #selector(editClicked(_:))), (duplicateButton, #selector(duplicateClicked(_:))),
                         (removeButton, #selector(removeClicked(_:))), (unpairButton, #selector(unpairClicked(_:))),
                         (connectButton, #selector(connectClicked(_:))), (orgButton, #selector(orgClicked(_:)))] {
            b.target = self
            b.action = sel
        }
        connectButton.keyEquivalent = "\r"
        unpairButton.toolTip = "Forget the PC's pinned key on this Mac. The next connection pairs again with a 6-digit code."
        removeButton.toolTip = "Delete the saved connection (and its pairing, unless another connection uses the same address)."
        let buttons = NSStackView(views: [add, editButton, duplicateButton, removeButton, unpairButton, NSView(), orgButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for v in [search, scroll, empty, buttons] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        w.contentView = content
        NotificationCenter.default.addObserver(forName: ManagedViewer.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.editor == nil else { return }
            self.reload()
        }
        reload()
    }

    func show() {
        ManagedViewer.shared.refreshHosts()
        hostRefresh?.invalidate()
        hostRefresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            ManagedViewer.shared.refreshHosts()
        }
        reload()
        if !window.isVisible && !window.setFrameUsingName("GlideViewerConnections") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-reads viewer.json and redraws, keeping the selection (or selecting `select`).
    func reload(select: String? = nil) {
        let keep = select ?? selectedRow?.id ?? selectedCloud.map { "cloud:" + $0.id }
        // A file that can't be read is reported in the list itself, not with an alert: this runs
        // whenever the window becomes key, which closing an alert would trigger again.
        var loadError: Error?
        do {
            config = try ViewerStore.load()
        } catch {
            config = ViewerConfig()
            loadError = error
        }
        let rows = config.connectionRows(filter: search.stringValue)
        let grouped = rows.contains { !$0.group.isEmpty }
        items = []
        var lastGroup: String?
        for r in rows {
            if grouped, !r.group.isEmpty, r.group.lowercased() != lastGroup?.lowercased() {
                items.append(.header(r.group))
            }
            lastGroup = r.group
            items.append(.row(r))
        }
        appendCloudItems()
        table.reloadData()
        let target = items.firstIndex {
            switch $0 {
            case let .row(r): return r.id == keep
            case let .cloud(h): return "cloud:" + h.id == keep
            default: return false
            }
        } ?? items.firstIndex { if case .row = $0 { return true } else { return false } }
        if let target {
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            table.scrollRowToVisible(target)
        } else {
            table.deselectAll(nil)
        }
        if let loadError {
            empty.stringValue = "Can't read viewer.json: \(loadError)\nFix or move the file (it may hold pinned host keys), then reopen this window."
        } else if config.connections.isEmpty && ManagedViewer.shared.isManaged {
            empty.stringValue = ""
        } else if config.connections.isEmpty {
            empty.stringValue = "No saved connections yet.\nClick Add… and enter the address of the PC running glide-host.exe."
        } else if rows.isEmpty {
            empty.stringValue = "No connection matches “\(search.stringValue)”."
        } else {
            empty.stringValue = ""
        }
        empty.isHidden = empty.stringValue.isEmpty
        updateButtons()
    }

    private var selectedRow: ConnectionRow? { row(at: table.selectedRow) }

    private var selectedCloud: CloudHost? { cloudHost(at: table.selectedRow) }

    private func cloudHost(at i: Int) -> CloudHost? {
        guard i >= 0, i < items.count, case let .cloud(h) = items[i] else { return nil }
        return h
    }

    /// The organization's section: its hosts once signed in, else what to do.
    private func appendCloudItems() {
        let mv = ManagedViewer.shared
        orgButton.isHidden = !mv.isManaged
        orgButton.title = mv.isSignedIn ? "Sign Out" : "Sign In…"
        orgButton.isEnabled = mv.isEnrolled
        guard mv.isManaged else { return }
        var header = "\(mv.orgName) — Glide Cloud"
        if let u = mv.user { header += " — \(u.label)" }
        items.append(.header(header))
        if !mv.isEnrolled {
            items.append(.cloudInfo(mv.status?.summary ?? "Connecting to Glide Cloud…"))
        } else if !mv.isSignedIn {
            items.append(.cloudInfo("Sign in to \(mv.orgName) to see the computers you can reach."))
        } else if mv.hosts.isEmpty {
            items.append(.cloudInfo(mv.hostsError.map { "Can't load the list: \($0)" } ?? (mv.refreshing ? "Loading…" : "No computers are available to you.")))
        } else {
            if mv.policy.updateRequired {
                items.append(.cloudInfo("Update Glide Viewer: \(mv.orgName) requires version \(mv.policy.minAppVersion ?? "?") or later."))
            }
            for h in mv.hosts { items.append(.cloud(h)) }
        }
    }

    private func row(at i: Int) -> ConnectionRow? {
        guard i >= 0, i < items.count, case let .row(r) = items[i] else { return nil }
        return r
    }

    private func saved(_ r: ConnectionRow) -> SavedConnection? { config.connections.first { $0.id == r.id } }

    private func updateButtons() {
        let r = selectedRow
        let lanBlocked = ManagedViewer.shared.lanBlockedReason != nil
        connectButton.isEnabled = (r?.supported == true && !lanBlocked) || (selectedCloud.map { $0.online && !ManagedViewer.shared.policy.updateRequired } ?? false)
        editButton.isEnabled = r != nil
        duplicateButton.isEnabled = r != nil
        removeButton.isEnabled = r != nil
        unpairButton.isEnabled = r?.paired == true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    private func textCell(_ tableView: NSTableView, _ id: String) -> NSTableCellView {
        (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell-" + id), owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = NSUserInterfaceItemIdentifier("cell-" + id)
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 20 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if self.row(at: row) != nil || cloudHost(at: row) != nil { return true }
        if row >= 0, row < items.count, case .cloudInfo = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        switch items[row] {
        case let .cloudInfo(text):
            guard tableColumn?.identifier.rawValue == Column.name.rawValue else { return nil }
            let cell = textCell(tableView, "cloudinfo")
            cell.textField?.stringValue = text
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = NSFont.systemFont(ofSize: 13)
            cell.toolTip = text
            return cell
        case let .cloud(h):
            guard let id = tableColumn?.identifier.rawValue, let col = Column(rawValue: id) else { return nil }
            let cell = textCell(tableView, id)
            var color = NSColor.labelColor
            let text: String
            switch col {
            case .name: text = h.name
            case .address: text = "Glide Cloud · " + (h.platform == "macos" ? "Mac" : h.platform == "windows" ? "PC" : h.platform)
            case .status:
                text = h.permissions.summary + (h.approval == .required ? " · asks first" : "")
                color = .secondaryLabelColor
            case .lastUsed:
                if h.online { text = "Online"; color = .systemGreen }
                else { text = "Offline"; color = .secondaryLabelColor }
            }
            cell.textField?.stringValue = text
            cell.textField?.textColor = color
            cell.textField?.font = col == .name ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.systemFont(ofSize: 13)
            cell.toolTip = col == .name ? "\(h.name)\n\(h.permissions.summary)\(h.tags.isEmpty ? "" : "\nTags: " + h.tags.joined(separator: ", "))" : nil
            return cell
        case let .header(g):
            let c = NSTableCellView()
            let t = NSTextField(labelWithString: g)
            t.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            t.textColor = .secondaryLabelColor
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        case let .row(r):
            guard let id = tableColumn?.identifier.rawValue, let col = Column(rawValue: id) else { return nil }
            let text: String
            var color = NSColor.labelColor
            switch col {
            case .name: text = r.favorite ? "★ \(r.name)" : r.name
            case .address: text = r.address
            case .status:
                text = ManagedViewer.shared.lanBlockedReason.map { "LAN \($0)" } ?? r.status
                if !r.paired { color = .secondaryLabelColor }
                if !r.supported || ManagedViewer.shared.lanBlockedReason != nil { color = .systemRed }
            case .lastUsed:
                text = r.lastUsed
                color = .secondaryLabelColor
            }
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell-" + id), owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = NSUserInterfaceItemIdentifier("cell-" + id)
                let tf = NSTextField(labelWithString: "")
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = text
            cell.textField?.textColor = color
            cell.textField?.font = col == .name ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.systemFont(ofSize: 13)
            cell.toolTip = col == .name && !r.group.isEmpty ? "\(r.name) (\(r.group))" : nil
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0, row(at: clicked) != nil, clicked != table.selectedRow {
            table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        if let h = cloudHost(at: clicked >= 0 ? clicked : table.selectedRow) {
            let ok = h.online && !ManagedViewer.shared.policy.updateRequired
            menu.addItem(withTitle: "Connect", action: ok ? #selector(connectClicked(_:)) : nil, keyEquivalent: "").target = self
            if h.permissions.control {
                menu.addItem(withTitle: "Connect View Only", action: ok ? #selector(connectViewOnly(_:)) : nil, keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Refresh List", action: #selector(refreshCloud(_:)), keyEquivalent: "").target = self
            return
        }
        guard let r = row(at: clicked >= 0 ? clicked : table.selectedRow) else {
            menu.addItem(withTitle: "Add…", action: #selector(addClicked(_:)), keyEquivalent: "").target = self
            return
        }
        let connect = menu.addItem(withTitle: "Connect", action: r.supported ? #selector(connectClicked(_:)) : nil, keyEquivalent: "")
        connect.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit…", action: #selector(editClicked(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateClicked(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: r.favorite ? "Remove from Favorites" : "Add to Favorites", action: #selector(toggleFavorite(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Address", action: #selector(copyAddress(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Unpair…", action: r.paired ? #selector(unpairClicked(_:)) : nil, keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove…", action: #selector(removeClicked(_:)), keyEquivalent: "").target = self
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Actions

    @objc func connectClicked(_ sender: Any?) {
        if let h = selectedCloud {
            guard h.online else { showError("“\(h.name)” is offline", "It isn't connected to Glide Cloud right now."); return }
            onConnectCloud?(h, false)
            return
        }
        if table.selectedRow >= 0, table.selectedRow < items.count, case .cloudInfo = items[table.selectedRow] {
            if ManagedViewer.shared.isEnrolled && !ManagedViewer.shared.isSignedIn { onSignIn?() }
            return
        }
        guard let r = selectedRow, let c = saved(r) else { return }
        if let why = ManagedViewer.shared.lanBlockedReason {
            showError("Can't connect to “\(r.name)”", "LAN connections are \(why). Use your organization's list below.")
            return
        }
        guard r.supported else {
            showError("Can't connect to “\(r.name)”", r.status == "Invalid address"
                ? "“\(c.address)” is not a valid address. Edit the connection to fix it."
                : "It is a \(c.platform) connection, which this viewer can't open.")
            return
        }
        onConnect?(c)
    }

    @objc private func connectViewOnly(_ sender: Any?) {
        if let h = selectedCloud, h.online { onConnectCloud?(h, true) }
    }

    @objc private func refreshCloud(_ sender: Any?) { ManagedViewer.shared.refreshHosts() }

    @objc private func orgClicked(_ sender: Any?) {
        let mv = ManagedViewer.shared
        if mv.isSignedIn {
            let a = NSAlert()
            a.messageText = "Sign out of \(mv.orgName)?"
            a.informativeText = "This Mac stops showing your organization's computers until you sign in again."
            a.addButton(withTitle: "Sign Out")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { mv.signOut() } }
        } else {
            onSignIn?()
        }
    }

    @objc func addClicked(_ sender: Any?) {
        openEditor(title: "Add Connection", saveTitle: "Add", draft: ConnectionDraft(), editing: nil)
    }

    @objc private func editClicked(_ sender: Any?) {
        guard let r = selectedRow, let c = saved(r) else { return }
        openEditor(title: "Edit “\(c.name)”", saveTitle: "Save", draft: ConnectionDraft(saved: c), editing: c)
    }

    private func openEditor(title: String, saveTitle: String, draft: ConnectionDraft, editing: SavedConnection?) {
        guard editor == nil, window.attachedSheet == nil else { return }
        if !window.isVisible { show() }
        let e = ConnectionEditor(title: title, saveTitle: saveTitle, draft: draft, groups: config.connectionGroups,
                                 defaultPort: ViewerTarget.standardPort(platform: editing?.platform))
        e.onSave = { [weak self] d in
            guard let self else { return nil }
            var failure: ConnectionDraftError?
            var newID: String?
            let err = ViewerStore.update { c in
                if let id = editing?.id {
                    if case let .failure(f) = c.updateConnection(id: id, d) { failure = f }
                } else {
                    switch c.addConnection(d) {
                    case let .success(s): newID = s.id
                    case let .failure(f): failure = f
                    }
                }
            }
            if let err { return ConnectionDraftError(.name, "Can't save viewer.json: \(err)") }
            if let failure { return failure }
            self.reload(select: newID ?? editing?.id)
            return nil
        }
        e.onClose = { [weak self] in self?.editor = nil }
        editor = e
        e.begin(on: window)
    }

    @objc private func duplicateClicked(_ sender: Any?) {
        guard let r = selectedRow else { return }
        var newID: String?
        if let err = ViewerStore.update({ newID = $0.duplicateConnection(id: r.id) }) {
            showError("Can't save viewer.json", "\(err)")
        }
        reload(select: newID)
    }

    @objc private func toggleFavorite(_ sender: Any?) {
        guard let r = selectedRow else { return }
        if let err = ViewerStore.update({ c in
            if let i = c.connections.firstIndex(where: { $0.id == r.id }) { c.connections[i].favorite.toggle() }
        }) {
            showError("Can't save viewer.json", "\(err)")
        }
        reload()
    }

    @objc private func copyAddress(_ sender: Any?) {
        guard let r = selectedRow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.address, forType: .string)
    }

    @objc func removeClicked(_ sender: Any?) {
        guard let r = selectedRow, window.attachedSheet == nil else { return }
        let shared = config.connections.contains { $0.id != r.id && $0.target?.pinKey == saved(r)?.target?.pinKey }
        let alert = NSAlert()
        alert.messageText = "Remove “\(r.name)”?"
        alert.informativeText = r.paired && !shared
            ? "The connection and its pairing are deleted from this Mac. Connecting to \(r.address) again means pairing again with a 6-digit code."
            : "The saved connection is deleted from this Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            if let err = ViewerStore.update({ _ = $0.removeConnection(id: r.id) }) {
                self.showError("Can't save viewer.json", "\(err)")
            }
            self.reload()
        }
    }

    @objc private func unpairClicked(_ sender: Any?) {
        guard let r = selectedRow, r.paired, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Unpair “\(r.name)”?"
        alert.informativeText = "This Mac forgets the PC's key for \(r.address). The next connection pairs again: choose Pair New Mac… on the PC and compare the 6-digit code."
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            if let err = ViewerStore.update({ $0.unpair(id: r.id) }) {
                self.showError("Can't save viewer.json", "\(err)")
            }
            self.reload()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up changes made elsewhere (a session that just paired or connected, another viewer).
        if editor == nil, window.attachedSheet == nil { reload() }
    }

    private func showError(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        if window.isVisible, window.attachedSheet == nil { a.beginSheetModal(for: window, completionHandler: nil) } else { a.runModal() }
    }
}

/// The table, with Delete / Backspace removing the selected connection.
final class ConnectionTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x33 || event.keyCode == 0x75 {  // Delete, Forward Delete
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The Add / Edit sheet: name, address, port, group, favorite. Validation is GlideCore's; a failed
/// save shows the message and points at the field, keeping the sheet open.
final class ConnectionEditor: NSObject {
    let panel: NSWindow
    private let name = NSTextField()
    private let address = NSTextField()
    private let port = NSTextField()
    private let group = NSComboBox()
    private let favorite = NSButton(checkboxWithTitle: "Favorite (listed first)", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    private weak var parent: NSWindow?
    /// Returns nil when saved (the sheet closes), else the problem to show.
    var onSave: ((ConnectionDraft) -> ConnectionDraftError?)?
    var onClose: (() -> Void)?

    init(title: String, saveTitle: String, draft: ConnectionDraft, groups: [String], defaultPort: UInt16) {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        super.init()

        name.stringValue = draft.name
        name.placeholderString = "e.g. Gaming PC (optional)"
        address.stringValue = draft.address
        address.placeholderString = "e.g. 192.168.1.20 or gaming-pc.local"
        port.stringValue = draft.port
        port.placeholderString = "\(defaultPort)"
        group.stringValue = draft.group
        group.placeholderString = "e.g. Home (optional)"
        group.addItems(withObjectValues: groups)
        group.completes = true
        group.numberOfVisibleItems = 8
        favorite.state = draft.favorite ? .on : .off
        for f in [name, address, port, group] as [NSTextField] { f.lineBreakMode = .byTruncatingTail; f.usesSingleLineMode = true }
        error.textColor = .systemRed
        error.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        error.isHidden = true

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let portHint = NSTextField(labelWithString: "Blank = \(defaultPort)")
        portHint.textColor = .secondaryLabelColor
        portHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let portRow = NSStackView(views: [port, portHint])
        portRow.spacing = 8
        port.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let grid = NSGridView(views: [
            [label("Name:"), name],
            [label("Address:"), address],
            [label("Port:"), portRow],
            [label("Group:"), group],
            [NSGridCell.emptyContentView, favorite],
            [NSGridCell.emptyContentView, error],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: saveTitle, target: self, action: #selector(saveClicked(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        panel.contentView = content
        panel.initialFirstResponder = draft.address.isEmpty ? address : name
        name.nextKeyView = address
        address.nextKeyView = port
        port.nextKeyView = group
        group.nextKeyView = favorite
        favorite.nextKeyView = name
    }

    func begin(on window: NSWindow) {
        parent = window
        window.beginSheet(panel) { [weak self] _ in self?.onClose?() }
    }

    private var draft: ConnectionDraft {
        ConnectionDraft(name: name.stringValue, address: address.stringValue, port: port.stringValue, group: group.stringValue,
                        favorite: favorite.state == .on)
    }

    @objc private func saveClicked(_ sender: Any?) {
        guard let problem = onSave?(draft) else {
            parent?.endSheet(panel, returnCode: .OK)
            return
        }
        error.stringValue = problem.message
        error.isHidden = false
        let field: NSView
        switch problem.field {
        case .name: field = name
        case .address: field = address
        case .port: field = port
        case .group: field = group
        }
        panel.makeFirstResponder(field)
        NSSound.beep()
    }

    @objc private func cancelClicked(_ sender: Any?) { parent?.endSheet(panel, returnCode: .cancel) }
}
