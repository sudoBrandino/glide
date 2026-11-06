import Foundation

/// Platform-independent clipboard-sync logic (PROTOCOL.md §5), shared by the host and the selftest.

public enum ClipboardText {
    /// Wire form: CRLF (and lone CR) -> LF.
    public static func toWire(_ s: String) -> String {
        guard s.utf8.contains(13) else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// 64-bit FNV-1a.
public func fnv1a64(_ d: Data, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var h = seed
    d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for b in p { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
    }
    return h
}

/// Echo suppression (PROTOCOL.md §5): a change marker for our own writes plus a hash of the last
/// content sent or applied. Not thread-safe; use it from one queue (the host uses the main thread).
public struct ClipboardEchoGuard {
    private var lastMarker: Int?
    private var ownMarker: Int?
    public private(set) var lastHash: UInt64?
    /// Marker at which the clipboard held `lastHash` content.
    private var hashMarker: Int?

    public init() {}

    /// Hash of the content that would be sent: the text if any, else the image bytes.
    /// `format` distinguishes text from image bytes that happen to be equal.
    public static func hash(format: UInt8, _ bytes: Data) -> UInt64 {
        fnv1a64(bytes, seed: fnv1a64(Data([format])))
    }

    public static func hash(_ c: ClipboardData) -> UInt64? {
        if let t = c.text { return hash(format: ClipboardData.formatText, Data(t.utf8)) }
        if let p = c.png { return hash(format: ClipboardData.formatPNG, p) }
        return nil
    }

    /// Record the marker as of session start (the current clipboard is not sent).
    public mutating func baseline(marker: Int) { lastMarker = marker }

    /// Called on every poll with the OS change marker. True when the clipboard changed since the
    /// last call and the change is not our own `didApply` write.
    public mutating func changed(marker: Int) -> Bool {
        if marker == lastMarker { return false }
        lastMarker = marker
        return marker != ownMarker
    }

    /// Called with the hash of local content about to be sent (`marker`: the clipboard's marker
    /// when it was read). False if it equals the last content sent or applied (nothing is sent).
    public mutating func shouldSend(hash: UInt64, marker: Int) -> Bool {
        if hash == lastHash { return false }
        lastHash = hash
        hashMarker = marker
        return true
    }

    /// Called before applying received content. False when it equals what we last sent or applied
    /// and the clipboard hasn't changed since: rewriting it would only drop richer formats (RTF,
    /// HTML, ...) the source app put there.
    public func shouldApply(hash: UInt64?, marker: Int) -> Bool {
        !(hash != nil && hash == lastHash && marker == hashMarker)
    }

    /// Called after writing received content to the local clipboard; `marker` is the OS change
    /// marker right after the write.
    public mutating func didApply(hash: UInt64?, marker: Int) {
        if let hash { lastHash = hash }
        hashMarker = marker
        ownMarker = marker
        lastMarker = marker
    }
}
