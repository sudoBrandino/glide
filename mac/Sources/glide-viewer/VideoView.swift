import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import GlideCore

/// What the video view reports (main thread).
protocol VideoViewInput: AnyObject {
    /// Pointer moved: normalized over the drawn video (PROTOCOL.md §3).
    func pointerMoved(x: Float, y: Float)
    func mouseButton(_ button: UInt8, down: Bool)
    func scrolled(dx: Double, dy: Double, precise: Bool)
}

/// One cursor image from the host (CursorShape, PROTOCOL.md §3), kept so it can be rebuilt at
/// another scale.
struct HostCursorShape {
    let w: Int, h: Int, hotX: Int, hotY: Int
    let bgra: Data
}

/// Shows decoded frames (AVSampleBufferDisplayLayer, letterboxed, aspect kept) and turns mouse
/// events into normalized host coordinates. y grows downward (flipped).
final class VideoView: NSView {
    weak var input: VideoViewInput?
    /// Encoded video size (pixels); zero until the first VideoConfig.
    var videoSize = CGSize.zero { didSet { updateCursorImage() } }
    /// Forward mouse events (connected and streaming).
    var active = false { didSet { updateCursorImage() } }

    private var hostShape: HostCursorShape?
    private var hostCursorVisible = true
    private var cursor: NSCursor = .arrow
    private static let blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
        return NSCursor(image: img, hotSpot: .zero)
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

    // MARK: Video

    /// Displays a decoded frame at once (no B-frames, no timing: every frame is shown on arrival).
    func show(_ pb: CVPixelBuffer) {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd) == noErr, let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb) == noErr,
              let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            let key: CFString = kCMSampleAttachmentKey_DisplayImmediately
            let yes: CFBoolean = kCFBooleanTrue
            CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(yes).toOpaque())
        }
        let l = displayLayer
        if l.status == .failed { l.flush() }
        l.enqueue(sb)
    }

    /// Drops the picture (new connection / new stream).
    func clear() { displayLayer.flushAndRemoveImage() }

    /// The rectangle the video occupies (view points).
    var videoRect: CGRect { PointerMath.fitRect(content: videoSize, in: bounds) }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    private func pointer(_ e: NSEvent) {
        guard active, videoSize.width > 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let n = PointerMath.normalize(p, in: videoRect, scale: window?.backingScaleFactor ?? 2)
        input?.pointerMoved(x: n.x, y: n.y)
    }

    private func button(_ e: NSEvent, _ b: UInt8, _ down: Bool) {
        guard active else { return }
        pointer(e)
        input?.mouseButton(b, down: down)
    }

    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseDown(with e: NSEvent) { if active { button(e, 0, true) } else { super.mouseDown(with: e) } }
    override func mouseUp(with e: NSEvent) { if active { button(e, 0, false) } else { super.mouseUp(with: e) } }
    override func rightMouseDown(with e: NSEvent) { if active { button(e, 1, true) } else { super.rightMouseDown(with: e) } }
    override func rightMouseUp(with e: NSEvent) { if active { button(e, 1, false) } else { super.rightMouseUp(with: e) } }
    override func otherMouseDown(with e: NSEvent) { if let b = otherButton(e) { button(e, b, true) } }
    override func otherMouseUp(with e: NSEvent) { if let b = otherButton(e) { button(e, b, false) } }

    /// NSEvent button 2 = middle, 3 = back, 4 = forward (PROTOCOL.md buttons 2/3/4).
    private func otherButton(_ e: NSEvent) -> UInt8? {
        guard active, (2...4).contains(e.buttonNumber) else { return nil }
        return UInt8(e.buttonNumber)
    }

    override func scrollWheel(with e: NSEvent) {
        guard active else { super.scrollWheel(with: e); return }
        input?.scrolled(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY), precise: e.hasPreciseScrollingDeltas)
    }

    // Keys are taken by KeyCapture before they get here; don't beep for the ones it lets through
    // while streaming (none, normally).
    override func keyDown(with e: NSEvent) { if !active { super.keyDown(with: e) } }
    override func keyUp(with e: NSEvent) { if !active { super.keyUp(with: e) } }

    // MARK: Cursor

    func setHostCursor(_ shape: HostCursorShape?) {
        hostShape = shape
        updateCursorImage()
    }

    func setHostCursorVisible(_ visible: Bool) {
        guard visible != hostCursorVisible else { return }
        hostCursorVisible = visible
        updateCursorImage()
    }

    func resetHostCursor() {
        hostShape = nil
        hostCursorVisible = true
        updateCursorImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateCursorImage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCursorImage()
    }

    /// Points per host pixel: the video is drawn at `videoRect` (points) for `videoSize` pixels.
    private var pointsPerHostPixel: CGFloat {
        guard videoSize.width > 0 else { return 1 / (window?.backingScaleFactor ?? 2) }
        return videoRect.width / videoSize.width
    }

    private func updateCursorImage() {
        var c = NSCursor.arrow
        if active {
            if !hostCursorVisible {
                c = VideoView.blankCursor
            } else if let s = hostShape, let made = VideoView.makeCursor(s, pointsPerPixel: pointsPerHostPixel) {
                c = made
            }
        }
        cursor = c
        window?.invalidateCursorRects(for: self)
        if let w = window, w.isKeyWindow {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p) { c.set() }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    /// CursorShape pixels (BGRA, straight alpha, top-down rows) -> NSCursor.
    static func makeCursor(_ s: HostCursorShape, pointsPerPixel k: CGFloat) -> NSCursor? {
        guard s.w > 0, s.h > 0, s.w <= 256, s.h <= 256, s.bgra.count >= s.w * s.h * 4, k > 0 else { return nil }
        guard let provider = CGDataProvider(data: s.bgra as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: s.w, height: s.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.w * 4, space: space, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(s.w) * k, height: CGFloat(s.h) * k))
        let hot = NSPoint(x: min(CGFloat(s.hotX), CGFloat(s.w - 1)) * k, y: min(CGFloat(s.hotY), CGFloat(s.h - 1)) * k)
        return NSCursor(image: img, hotSpot: hot)
    }
}
