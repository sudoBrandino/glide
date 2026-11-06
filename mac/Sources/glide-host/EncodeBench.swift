import CoreText
import CoreVideo
import Foundation
import GlideCore
import VideoToolbox

/// `glide-host --encode-bench [SECONDS]`: offline encoder timing for docs/LATENCY.md
/// (hypothesis c). Encodes synthetic 2560x1440 "desktop" frames (a page of text, NV12 like the
/// SCK base stream) through the same `VideoEncoder` the host uses, one frame in flight, paced at
/// 60 fps, with normal and low-latency rate control, for a full-screen scroll and for a small
/// typing-sized change. Never touches ScreenCaptureKit or the network. The hardware encoder is
/// shared with a running host, so run it while the live session is idle.
func runEncodeBench(seconds: Double) -> Never {
    let w = 2560, h = 1440, fps = 60
    // A tall page of text, rendered once (BGRA), scrolled through per frame.
    let pageH = h * 3
    let page = CGContext(data: nil, width: w, height: pageH, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    page.setFillColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    page.fill(CGRect(x: 0, y: 0, width: w, height: pageH))
    let font = CTFontCreateWithName("Menlo" as CFString, 15, nil)
    let words = ["func", "let", "var", "return", "glide", "latency", "encoder", "frame", "capture", "present", "scanout", "{", "}", "=", "(", ")", "//", "0x1F"]
    var seed: UInt32 = 1
    func rnd(_ n: Int) -> Int { seed = seed &* 1_103_515_245 &+ 12345; return Int(seed >> 16) % n }
    for line in 0..<(pageH / 20) {
        var s = String(repeating: " ", count: rnd(12))
        while s.count < 150 { s += words[rnd(words.count)] + " " }
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: CGFloat(rnd(3)) * 0.25, alpha: 1)])
        page.textPosition = CGPoint(x: 24, y: CGFloat(pageH - 20 * (line + 1)))
        CTLineDraw(CTLineCreateWithAttributedString(attr), page)
    }
    let pagePx = page.data!.assumingMemoryBound(to: UInt8.self)

    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    VTSessionSetProperty(transfer!, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    func frame(scrollY: Int, caret: Int?) -> CVPixelBuffer {
        var bgra: CVPixelBuffer?, nv12: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &bgra)
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &nv12)
        CVPixelBufferLockBaseAddress(bgra!, [])
        let dst = CVPixelBufferGetBaseAddress(bgra!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(bgra!)
        for y in 0..<h { memcpy(dst + y * bpr, pagePx + ((y + scrollY) % pageH) * w * 4, w * 4) }
        if let c = caret {  // a typing-sized change: one "character" cell toggles
            for y in 700..<718 { for x in 0..<9 { (dst + y * bpr + (1200 + c * 9 + x) * 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee = 0xFF20_2020 } } }
        }
        CVPixelBufferUnlockBaseAddress(bgra!, [])
        VTPixelTransferSessionTransferImage(transfer!, from: bgra!, to: nv12!)
        return nv12!
    }

    struct Result { var ms: [Double] = []; var bytes = 0 }
    func run(lowLatency: Bool, scroll: Bool, pace: Int = fps, syntheticPts: Bool = false, realTime: Bool = true) -> Result {
        if lowLatency { setenv("GLIDE_LL", "1", 1) } else { unsetenv("GLIDE_LL") }
        let bps = Int(Double(w * h * fps) * 0.2)
        let enc = try! VideoEncoder(.init(width: w, height: h, codec: .hevc, chroma: .yuv420, fps: fps, bitrate: bps))
        if !realTime { enc.setProperty(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse) }
        var r = Result()
        let n = max(4, Int(seconds * Double(pace)))
        let sem = DispatchSemaphore(value: 0)
        let start = Date()
        for i in 0..<n {
            let pb = frame(scrollY: scroll ? i * 6 : 0, caret: scroll ? nil : i)
            let pts = syntheticPts ? CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)) : CMTime(value: CMTimeValue(hostTimeMicros()), timescale: 1_000_000)
            enc.encode(pb, pts: pts) { data, _, _, ms in
                if i > 0 { r.ms.append(ms); r.bytes += data.count }  // skip the first (IDR)
                sem.signal()
            }
            sem.wait()  // one frame in flight, like the host
            let due = start.addingTimeInterval(Double(i + 1) / Double(pace))
            if due > Date() { Thread.sleep(until: due) }
        }
        enc.invalidate()
        return r
    }
    func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count) * p))] }
    print("encode bench: HEVC 4:2:0 \(w)x\(h) @ \(fps) fps pacing, auto bitrate \(Int(Double(w * h * fps) * 0.2) / 1_000_000) Mbps, 1 frame in flight, \(seconds)s per run")
    for scroll in [true, false] {
        for ll in [false, true] {
            let r = run(lowLatency: ll, scroll: scroll)
            print(String(format: "  %-26@ %-14@ encode ms p50 %5.2f  p95 %5.2f  max %5.2f   %6.1f KB/frame",
                         (scroll ? "full-screen text scroll" : "typing (one cell changes)") as NSString, (ll ? "low-latency RC" : "normal RC") as NSString,
                         pct(r.ms, 0.5), pct(r.ms, 0.95), r.ms.max() ?? .nan, Double(r.bytes) / Double(max(1, r.ms.count)) / 1024))
        }
    }
    // Interactive desktop use is bursty: a keystroke produces one isolated frame. Does the
    // encoder take longer when frames are sparse (media engine clocked down between frames)?
    for pace in [20, 5, 2] {
        for ll in [false, true] {
            let r = run(lowLatency: ll, scroll: false, pace: pace)
            print(String(format: "  %-26@ %-14@ encode ms p50 %5.2f  p95 %5.2f  max %5.2f   (%d frames, %.1f KB/frame)",
                         "isolated frames @ \(pace) fps" as NSString, (ll ? "low-latency RC" : "normal RC") as NSString,
                         pct(r.ms, 0.5), pct(r.ms, 0.95), r.ms.max() ?? .nan, r.ms.count, Double(r.bytes) / Double(max(1, r.ms.count)) / 1024))
        }
    }
    // Mitigation experiments on the same session: PTS spaced as if frames were consecutive at
    // `fps` (VT real-time scheduling looks at PTS gaps), and RealTime off.
    for (label, syn, rt) in [("synthetic 1/60 s PTS", true, true), ("RealTime=false", false, false)] {
        let r = run(lowLatency: false, scroll: false, pace: 2, syntheticPts: syn, realTime: rt)
        print(String(format: "  %-26@ %-14@ encode ms p50 %5.2f  p95 %5.2f  max %5.2f   (%d frames, %.1f KB/frame)",
                     "isolated @ 2 fps, \(label)" as NSString, "normal RC" as NSString, pct(r.ms, 0.5), pct(r.ms, 0.95), r.ms.max() ?? .nan, r.ms.count,
                     Double(r.bytes) / Double(max(1, r.ms.count)) / 1024))
    }
    // Mitigation experiment: a tiny second session encoding a 256x256 frame at `warm` Hz keeps
    // the media engine busy; does the isolated main-session frame get fast again?
    for warm in [30, 60] {
        unsetenv("GLIDE_LL")
        let tiny = try! VideoEncoder(.init(width: 256, height: 256, codec: .hevc, chroma: .yuv420, fps: warm, bitrate: 1_000_000))
        var tpb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &tpb)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "warm"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(warm))
        timer.setEventHandler { tiny.encode(tpb!, pts: CMTime(value: CMTimeValue(hostTimeMicros()), timescale: 1_000_000)) { _, _, _, _ in } }
        timer.resume()
        Thread.sleep(forTimeInterval: 0.3)
        let r = run(lowLatency: false, scroll: false, pace: 2)
        timer.cancel()
        tiny.invalidate()
        print(String(format: "  %-26@ %-14@ encode ms p50 %5.2f  p95 %5.2f  max %5.2f   (%d frames)",
                     "isolated @ 2 fps + warm \(warm)Hz" as NSString, "normal RC" as NSString, pct(r.ms, 0.5), pct(r.ms, 0.95), r.ms.max() ?? .nan, r.ms.count))
    }
    unsetenv("GLIDE_LL")
    exit(0)
}
