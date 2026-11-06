import AppKit
import CryptoKit
import GlideCore

/// Watches the system cursor image and reports shape changes (as BGRA in host pixels).
final class CursorMonitor {
    struct Shape { let id: UInt32; let w: Int; let h: Int; let hotX: Int; let hotY: Int; let bgra: Data }

    /// Called on the main thread. `isNew` = first time this shape id is seen in this session.
    var onShape: ((Shape, _ isNew: Bool) -> Void)?
    private var timer: Timer?
    private var known: [Data: UInt32] = [:]   // digest -> id
    private var shapes: [UInt32: Shape] = [:]
    private var current: UInt32?
    private var nextId: UInt32 = 1
    var scale: CGFloat = 1

    func start() {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            tick()
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in timer?.invalidate(); timer = nil; current = nil; known.removeAll(); shapes.removeAll() }
    }

    /// Forget which shapes the client has (e.g. new connection).
    func resetSession() { DispatchQueue.main.async { [self] in current = nil; known.removeAll(); shapes.removeAll() } }

    private func tick() {
        guard let cursor = NSCursor.currentSystem else { return }
        let img = cursor.image
        let w = max(1, Int((img.size.width * scale).rounded())), h = max(1, Int((img.size.height * scale).rounded()))
        guard w <= 256, h <= 256 else { return }
        var buf = Data(count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard ok else { return }
        // CG gives premultiplied BGRA, top-down rows (bitmap memory starts at the top row). Un-premultiply.
        buf.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                let a = Int(b[i + 3])
                if a > 0 && a < 255 {
                    b[i] = UInt8(min(255, Int(b[i]) * 255 / a))
                    b[i + 1] = UInt8(min(255, Int(b[i + 1]) * 255 / a))
                    b[i + 2] = UInt8(min(255, Int(b[i + 2]) * 255 / a))
                }
                i += 4
            }
        }
        let hot = cursor.hotSpot
        var hasher = SHA256()
        hasher.update(data: buf)
        withUnsafeBytes(of: (w, h, Int(hot.x * 100), Int(hot.y * 100))) { hasher.update(bufferPointer: $0) }
        let digest = Data(hasher.finalize())
        if let id = known[digest] {
            if id != current { current = id; onShape?(shapes[id]!, false) }
            return
        }
        let id = nextId; nextId += 1
        let shape = Shape(id: id, w: w, h: h, hotX: min(w - 1, Int((hot.x * scale).rounded())), hotY: min(h - 1, Int((hot.y * scale).rounded())), bgra: buf)
        known[digest] = id
        shapes[id] = shape
        current = id
        onShape?(shape, true)
    }
}
