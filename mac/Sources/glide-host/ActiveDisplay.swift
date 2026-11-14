import CoreGraphics

/// The display Glide serves: the `--display` pin while that display is online, otherwise whatever
/// is the main display right now.
///
/// Never cache a display ID across a session. IDs go stale when the lid closes or a monitor is
/// swapped, and CoreGraphics keeps answering for an offline ID (CGDisplayBounds returns its last
/// size), so a stale ID silently maps input onto the wrong rectangle instead of failing.
enum ActiveDisplay {
    /// `--display N`. Set once at startup, before any session starts.
    static var pinned: CGDirectDisplayID?

    static func current() -> CGDirectDisplayID {
        if let p = pinned, isOnline(p) { return p }
        return CGMainDisplayID()
    }

    static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0
    }
}
