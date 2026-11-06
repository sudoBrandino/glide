// Compares what the Mac renders (ground truth) with what the viewer shows, tile by tile.
// usage: compare <mac.png> <viewer.png> <out-heatmap.png> [viewerCropX viewerCropY viewerCropW viewerCropH]
// The Mac image is resampled to the viewer crop size. Prints per-tile error stats and the worst
// tiles; writes a heatmap (viewer image dimmed, tiles tinted by error).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ p: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't load \(p)") }
    return img
}

func rgba(_ img: CGImage, w: Int, h: Int, crop: CGRect? = nil) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let src = crop.flatMap { img.cropping(to: $0) } ?? img
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: compare mac.png viewer.png out.png [x y w h]"); exit(2) }
let mac = load(a[1]), viewer = load(a[2])
var crop = CGRect(x: 0, y: 0, width: viewer.width, height: viewer.height)
if a.count >= 8 { crop = CGRect(x: Double(a[4])!, y: Double(a[5])!, width: Double(a[6])!, height: Double(a[7])!) }
let W = Int(crop.width), H = Int(crop.height)
let m = rgba(mac, w: W, h: H)
let v = rgba(viewer, w: W, h: H, crop: crop)

let T = 32
let tx = (W + T - 1) / T, ty = (H + T - 1) / T
var tileErr = [Double](repeating: 0, count: tx * ty)
var hist = [Int](repeating: 0, count: 8)
for j in 0..<ty {
    for i in 0..<tx {
        var sum = 0.0, n = 0
        for y in (j * T)..<min(H, (j + 1) * T) {
            for x in (i * T)..<min(W, (i + 1) * T) {
                let o = (y * W + x) * 4
                let d = abs(Int(m[o]) - Int(v[o])) + abs(Int(m[o + 1]) - Int(v[o + 1])) + abs(Int(m[o + 2]) - Int(v[o + 2]))
                sum += Double(d) / 3; n += 1
            }
        }
        let e = sum / Double(max(n, 1))
        tileErr[j * tx + i] = e
        hist[min(7, Int(e / 4))] += 1
    }
}
let sorted = tileErr.enumerated().sorted { $0.element > $1.element }
print(String(format: "tiles %dx%d (%dpx). mean err %.2f/255, median %.2f", tx, ty, T,
             tileErr.reduce(0, +) / Double(tileErr.count), tileErr.sorted()[tileErr.count / 2]))
print("histogram (mean abs err per tile, buckets of 4/255):", hist.enumerated().map { "\($0.offset * 4)-\($0.offset * 4 + 4): \($0.element)" }.joined(separator: "  "))
print("worst tiles (x,y px -> err):", sorted.prefix(12).map { String(format: "(%d,%d)->%.0f", ($0.offset % tx) * T, ($0.offset / tx) * T, $0.element) }.joined(separator: " "))

// Heatmap
var out = v
for j in 0..<ty {
    for i in 0..<tx {
        let e = tileErr[j * tx + i]
        let t = min(1.0, e / 24)
        for y in (j * T)..<min(H, (j + 1) * T) {
            for x in (i * T)..<min(W, (i + 1) * T) {
                let o = (y * W + x) * 4
                out[o] = UInt8(min(255.0, Double(out[o]) * 0.35 + 255 * t))
                out[o + 1] = UInt8(Double(out[o + 1]) * 0.35 * (1 - t))
                out[o + 2] = UInt8(Double(out[o + 2]) * 0.35 * (1 - t))
            }
        }
    }
}
let ctx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
print("heatmap -> \(a[3])")
