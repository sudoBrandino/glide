import CoreMedia
import Foundation
import GlideCore
@preconcurrency import ScreenCaptureKit

/// System audio -> wire (docs/PROTOCOL.md §3.2). Rides on VideoPipeline's base SCStream (one
/// capture stream; `capturesAudio` + an `.audio` output on its own queue), converts each SCK
/// buffer to s16le and splits it into ≤10 ms AudioFrames, sent immediately.
///
/// Priority: audio is ~1.5 Mbit/s and never waits for video; it is only dropped when the
/// connection backlog is far past the video backpressure limit (`canSend`).
final class AudioPipeline: NSObject, SCStreamOutput, @unchecked Sendable {
    static let sampleRate = 48_000
    static let channels = 2

    /// Called on `queue` before the first frame and whenever the format changes (or after re-enable).
    var onConfig: ((AudioConfig) -> Void)?
    /// Called on `queue` per AudioFrame.
    var onFrame: ((_ seq: UInt32, _ captureUs: UInt64, _ pcm: Data) -> Void)?
    /// False when the network backlog is so large that audio should be dropped.
    var canSend: () -> Bool = { true }

    let queue = DispatchQueue(label: "glide.audio", qos: .userInteractive)

    // queue-confined
    private var enabled = true
    /// Nothing may be sent before the session's ServerHello (the viewer requires it first).
    private var armed = false
    private var sentConfig: AudioConfig?
    private var seq: UInt32 = 0
    private var loggedFormat = false
    private var errorLogs = 0
    private var stats = Stats()
    private struct Stats {
        var buffers = 0, frames = 0, dropped = 0, minFrames = Int.max, maxFrames = 0
        var lastCallbackUs: UInt64 = 0, maxGapUs: UInt64 = 0
        var lateUs: [Double] = []  // callback time - capture time of the buffer's last sample
        var since = hostTimeMicros()
    }

    /// Adds audio capture to a stream configuration (call before creating the SCStream).
    func configure(_ cfg: SCStreamConfiguration) {
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Self.sampleRate
        cfg.channelCount = Self.channels
    }

    /// Registers this object as the stream's audio output.
    func attach(to stream: SCStream) throws {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    }

    /// Call once ServerHello has been sent.
    func arm() { queue.async { self.armed = true } }

    /// AudioEnable from the viewer. Re-enabling re-sends AudioConfig before the next frame.
    func setEnabled(_ on: Bool) {
        queue.async {
            if on && !self.enabled { self.sentConfig = nil }
            self.enabled = on
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        let now = hostTimeMicros()
        let (cfg, packets): (AudioConfig, [AudioPacket])
        do { (cfg, packets) = try AudioPCM.packetize(sb) } catch {
            if errorLogs < 5 { errorLogs += 1; log("audio: dropping buffer: \(error)") }
            return
        }
        let n = packets.reduce(0) { $0 + $1.frames }
        if !loggedFormat, let fd = CMSampleBufferGetFormatDescription(sb), let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            loggedFormat = true
            log("audio: capturing \(AudioPCM.describe(a.pointee)), \(n) frames per buffer -> \(packets.count) wire frame(s) of ≤\(cfg.frameSamples)")
        }
        noteStats(now: now, frames: n, cfg: cfg, firstUs: packets.first?.captureUs)
        guard armed, enabled, !packets.isEmpty else { return }
        if sentConfig != cfg {
            sentConfig = cfg
            onConfig?(cfg)
        }
        for p in packets {
            let s = seq
            seq &+= 1
            if canSend() { onFrame?(s, p.captureUs, p.pcm) } else { stats.dropped += 1 }
        }
    }

    private func noteStats(now: UInt64, frames n: Int, cfg: AudioConfig, firstUs: UInt64?) {
        stats.buffers += 1
        stats.frames += n
        stats.minFrames = min(stats.minFrames, n)
        stats.maxFrames = max(stats.maxFrames, n)
        if stats.lastCallbackUs > 0 { stats.maxGapUs = max(stats.maxGapUs, now - stats.lastCallbackUs) }
        stats.lastCallbackUs = now
        if let t = firstUs, cfg.sampleRate > 0 {
            let lastSampleUs = Double(t) + Double(n) * 1e6 / Double(cfg.sampleRate)
            stats.lateUs.append(Double(now) - lastSampleUs)
        }
        // Every 30 s: what SCK actually delivers (buffer size, cadence, delivery delay).
        if now - stats.since >= 30_000_000 {
            let late = stats.lateUs.sorted()
            let p50 = late.isEmpty ? 0 : late[late.count / 2] / 1000
            let mx = late.last.map { $0 / 1000 } ?? 0
            let secs = Double(now - stats.since) / 1e6
            log(String(format: "audio stats: %.0f buffers/s, %d-%d frames/buffer, max gap %.1f ms, delivery delay p50 %.1f ms max %.1f ms, dropped %d frames%@",
                       Double(stats.buffers) / secs, stats.minFrames, stats.maxFrames, Double(stats.maxGapUs) / 1000, p50, mx, stats.dropped, enabled ? "" : " (muted by viewer)"))
            stats = Stats()
            stats.lastCallbackUs = now
        }
    }
}
