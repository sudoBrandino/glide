import AppKit

/// A small floating panel that sits under System Settings while it shows a privacy list (Screen
/// Recording, Accessibility), with Glide Host's icon to drag into the list. macOS doesn't always
/// list an app that asked (an earlier grant was reset, or the request came from another copy);
/// dropping the app on the list adds it, like the list's + button, without a file dialog.
///
/// The panel follows the System Settings window, and closes when the permission is granted, when
/// System Settings closes or quits, or with its close button.
final class PermissionDragHelper {
    static let shared = PermissionDragHelper()

    private var panel: NSPanel?
    private var timer: Timer?
    private var isGranted: () -> Bool = { false }
    /// System Settings may take a moment to open its window; give up if it never shows.
    private var waitUntil = Date.distantPast
    private var sawWindow = false

    static let settingsBundleID = "com.apple.systempreferences"

    /// Shows the helper for `permission` ("Screen Recording") until `granted()` is true.
    func show(permission: String, granted: @escaping () -> Bool) {
        close()
        isGranted = granted
        waitUntil = Date().addingTimeInterval(10)
        sawWindow = false
        let p = makePanel(permission: permission)
        panel = p
        position()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
    }

    private func tick() {
        if isGranted() { close(); return }
        position()
    }

    /// Puts the panel just under the System Settings window, centred; else beside it (right, then
    /// left), level with its bottom; else inside its bottom edge. Hidden while the window isn't
    /// on screen.
    private func position() {
        guard let panel else { return }
        guard let w = Self.settingsWindowFrame() else {
            panel.orderOut(nil)
            if sawWindow || Date() > waitUntil { close() }  // closed or quit, or never opened
            return
        }
        sawWindow = true
        let size = panel.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(w) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? w
        let gap: CGFloat = 8
        var origin: NSPoint
        if w.minY - size.height - gap >= visible.minY {
            origin = NSPoint(x: w.midX - size.width / 2, y: w.minY - size.height - gap)
        } else if w.maxX + gap + size.width <= visible.maxX {
            origin = NSPoint(x: w.maxX + gap, y: w.minY)
        } else if w.minX - gap - size.width >= visible.minX {
            origin = NSPoint(x: w.minX - gap - size.width, y: w.minY)
        } else {
            origin = NSPoint(x: w.midX - size.width / 2, y: w.minY + 16)
        }
        origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        origin.y = min(max(origin.y, visible.minY + gap), visible.maxY - size.height - gap)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The frontmost normal window of System Settings, in Cocoa screen coordinates (window bounds
    /// need no Screen Recording permission; titles would).
    static func settingsWindowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {  // front to back
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 300, height > 200 else { continue }
            return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
        }
        return nil
    }

    private func makePanel(permission: String) -> NSPanel {
        let width: CGFloat = 380, height: CGFloat = 96
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false  // Glide Host is a background app; System Settings is active
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let app = Bundle.main.bundleURL
        let icon = DragIconView(url: app, icon: NSWorkspace.shared.icon(forFile: app.path))
        icon.frame = NSRect(x: 16, y: (height - 60) / 2, width: 60, height: 60)
        icon.toolTip = "Drag Glide Host into the \(permission) list"
        bg.addSubview(icon)

        let textX: CGFloat = 90, textW = width - textX - 34
        let title = NSTextField(labelWithString: "Glide Host not in the list?")
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: textX, y: height - 16 - 18, width: textW, height: 18)
        bg.addSubview(title)
        let body = NSTextField(wrappingLabelWithString: "Drag this icon into the \(permission) list, then switch Glide Host on.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = textW
        body.frame = NSRect(x: textX, y: 14, width: textW, height: height - 16 - 18 - 14 - 2)
        bg.addSubview(body)

        let x = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                         target: self, action: #selector(closeClicked))
        x.isBordered = false
        x.contentTintColor = .tertiaryLabelColor
        x.frame = NSRect(x: width - 30, y: height - 30, width: 20, height: 20)
        bg.addSubview(x)

        p.contentView = bg
        return p
    }

    @objc private func closeClicked() { close() }
}

/// Glide Host's icon as a drag source: the drop is the app bundle's file URL, which a privacy
/// list in System Settings accepts.
private final class DragIconView: NSView, NSDraggingSource {
    let url: URL
    let icon: NSImage

    init(url: URL, icon: NSImage) {
        self.url = url
        self.icon = icon
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }

    // The panel never becomes key; the first click must still start a drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : []
    }
}
