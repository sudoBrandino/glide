import Foundation

/// Sanity limits for the viewer's view size (ClientHello / ViewSize `view_w` x `view_h`,
/// PROTOCOL.md §3). The host sizes capture, the virtual display and the display-mode policy
/// from it, so a nonsense value (1 x 1 makes a 0 x 0 capture once rounded to even) must never get
/// that far.
public enum ViewSizeLimits {
    public static let minWidth = 320
    public static let minHeight = 200
    /// Above any monitor a viewer can present on 1:1 (the encoder and `--max-width` cap further).
    public static let maxWidth = 16384
    public static let maxHeight = 16384

    /// The size to use for a reported `w` x `h`: nil when the viewer didn't report one (either
    /// dimension 0 means "unknown"), else each dimension clamped to the limits above.
    public static func clamp(_ w: Int, _ h: Int) -> (w: Int, h: Int)? {
        guard w > 0, h > 0 else { return nil }
        return (Swift.min(Swift.max(w, minWidth), maxWidth), Swift.min(Swift.max(h, minHeight), maxHeight))
    }

    /// The encoded (capture) size for a display of `pixelW` x `pixelH` pixels, scaled down to at
    /// most `maxWidth` wide (aspect kept) and rounded down to even. Never smaller than 2 x 2, even
    /// for a degenerate `maxWidth` or display size.
    public static func captureSize(pixelW: Int, pixelH: Int, maxWidth: Int) -> (w: Int, h: Int) {
        var pw = Swift.max(pixelW, 2), ph = Swift.max(pixelH, 2)
        let limit = Swift.max(maxWidth, minWidth)
        if pw > limit {
            ph = ph * limit / pw
            pw = limit
        }
        return (Swift.max(pw & ~1, 2), Swift.max(ph & ~1, 2))
    }
}
