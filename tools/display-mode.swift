import CoreGraphics
import Foundation
// usage: modes [set W H hidpi]
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
let cur = CGDisplayCopyDisplayMode(d)!
print("display \(d) current: \(cur.width)x\(cur.height) pixels \(cur.pixelWidth)x\(cur.pixelHeight) @\(cur.refreshRate)")
let a = CommandLine.arguments
if a.count == 5, a[1] == "set", let w = Int(a[2]), let h = Int(a[3]) {
    let hidpi = a[4] == "hidpi"
    guard let m = modes.first(where: { $0.width == w && $0.height == h && ($0.pixelWidth > $0.width) == hidpi && $0.isUsableForDesktopGUI() }) else { print("mode not found"); exit(1) }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
    let r = CGCompleteDisplayConfiguration(cfg, .permanently)
    print("set \(m.width)x\(m.height) pixels \(m.pixelWidth)x\(m.pixelHeight): \(r == .success ? "ok" : "error \(r.rawValue)")")
} else {
    for m in modes where m.isUsableForDesktopGUI() && m.width >= 1600 { print("  \(m.width)x\(m.height)  pixels \(m.pixelWidth)x\(m.pixelHeight) @\(m.refreshRate)") }
}
