import CoreGraphics
import CoreVideo
import Foundation

/// Finds the tiles that actually changed between two NV12 (420v/420f) frames.
///
/// ScreenCaptureKit's dirty rects are coarse: Electron/Chromium apps (T3, VS Code, Discord...) report
/// their whole window dirty for a one-line change. We compare real pixels, but only inside SCK's
/// dirty rects, in `tileW`x`tileH` tiles (Y and interleaved CbCr planes).
enum TileDiff {
    static let tileW = 64, tileH = 32

    /// Returns merged changed rects in pixel coordinates, or nil if the buffers can't be compared
    /// (different size/format). An empty array means nothing changed.
    static func changedRects(prev: CVPixelBuffer, cur: CVPixelBuffer, within bounds: [CGRect]?) -> [CGRect]? {
        let W = CVPixelBufferGetWidth(cur), H = CVPixelBufferGetHeight(cur)
        guard CVPixelBufferGetWidth(prev) == W, CVPixelBufferGetHeight(prev) == H,
              CVPixelBufferGetPixelFormatType(prev) == CVPixelBufferGetPixelFormatType(cur),
              CVPixelBufferGetPlaneCount(cur) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(prev, .readOnly)
        CVPixelBufferLockBaseAddress(cur, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(cur, .readOnly)
            CVPixelBufferUnlockBaseAddress(prev, .readOnly)
        }
        guard let pY = CVPixelBufferGetBaseAddressOfPlane(prev, 0), let cY = CVPixelBufferGetBaseAddressOfPlane(cur, 0),
              let pC = CVPixelBufferGetBaseAddressOfPlane(prev, 1), let cC = CVPixelBufferGetBaseAddressOfPlane(cur, 1) else { return nil }
        let pYs = CVPixelBufferGetBytesPerRowOfPlane(prev, 0), cYs = CVPixelBufferGetBytesPerRowOfPlane(cur, 0)
        let pCs = CVPixelBufferGetBytesPerRowOfPlane(prev, 1), cCs = CVPixelBufferGetBytesPerRowOfPlane(cur, 1)

        let tx = (W + tileW - 1) / tileW, ty = (H + tileH - 1) / tileH
        var checked = [Bool](repeating: false, count: tx * ty)
        var changed = [Bool](repeating: false, count: tx * ty)
        let regions = bounds ?? [CGRect(x: 0, y: 0, width: W, height: H)]

        for r in regions {
            let x0 = max(0, Int(r.minX) / tileW), x1 = min(tx - 1, (Int(r.maxX.rounded(.up)) - 1) / tileW)
            let y0 = max(0, Int(r.minY) / tileH), y1 = min(ty - 1, (Int(r.maxY.rounded(.up)) - 1) / tileH)
            guard x1 >= x0, y1 >= y0 else { continue }
            for j in y0...y1 {
                for i in x0...x1 {
                    let k = j * tx + i
                    if checked[k] { continue }
                    checked[k] = true
                    let px = i * tileW, pw = min(tileW, W - px)
                    let py = j * tileH, ph = min(tileH, H - py)
                    var diff = false
                    // Luma rows
                    var row = py
                    while row < py + ph {
                        if memcmp(pY + row * pYs + px, cY + row * cYs + px, pw) != 0 { diff = true; break }
                        row += 1
                    }
                    // Chroma rows (half height, interleaved CbCr: same byte width as luma)
                    if !diff {
                        var crow = py / 2
                        while crow < (py + ph + 1) / 2 {
                            if memcmp(pC + crow * pCs + px, cC + crow * cCs + px, pw & ~1) != 0 { diff = true; break }
                            crow += 1
                        }
                    }
                    changed[k] = diff
                }
            }
        }

        // Merge: horizontal runs per tile row, then stack identical runs vertically.
        var open: [Int: CGRect] = [:]  // key = x0 << 16 | x1 (tile indices)
        var out: [CGRect] = []
        for j in 0..<ty {
            var runs: [(Int, Int)] = []
            var i = 0
            while i < tx {
                if changed[j * tx + i] {
                    let s = i
                    while i < tx && changed[j * tx + i] { i += 1 }
                    runs.append((s, i - 1))
                } else { i += 1 }
            }
            var next: [Int: CGRect] = [:]
            for (s, e) in runs {
                let key = s << 16 | e
                let rx = s * tileW, rw = min((e + 1) * tileW, W) - rx
                let ry = j * tileH, rh = min(tileH, H - ry)
                if var r = open.removeValue(forKey: key) {
                    r.size.height += CGFloat(rh)
                    next[key] = r
                } else {
                    next[key] = CGRect(x: rx, y: ry, width: rw, height: rh)
                }
            }
            out.append(contentsOf: open.values)
            open = next
        }
        out.append(contentsOf: open.values)
        return out
    }
}
