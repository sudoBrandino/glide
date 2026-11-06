import AudioToolbox
import CoreMedia
import Foundation

/// Audio wire codecs (docs/PROTOCOL.md §3.2).
public enum AudioCodec: UInt8, Sendable {
    case off = 0
    case pcmS16 = 1
    case opus = 2  // reserved
}

/// `AudioConfig` (0x60) body.
public struct AudioConfig: Equatable, Sendable {
    public var codec: AudioCodec
    public var sampleRate: UInt32
    public var channels: UInt8
    /// Nominal samples per channel per AudioFrame (informational).
    public var frameSamples: UInt16

    public init(codec: AudioCodec, sampleRate: UInt32, channels: UInt8, frameSamples: UInt16) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels; self.frameSamples = frameSamples
    }

    public static let off = AudioConfig(codec: .off, sampleRate: 0, channels: 0, frameSamples: 0)

    func write(_ w: inout ByteWriter) {
        w.u8(codec.rawValue); w.u32(sampleRate); w.u8(channels); w.u16(frameSamples)
    }

    static func read(_ r: inout ByteReader) throws -> AudioConfig {
        let c = AudioCodec(rawValue: try r.u8()) ?? .off
        return AudioConfig(codec: c, sampleRate: try r.u32(), channels: try r.u8(), frameSamples: try r.u16())
    }
}

/// One wire AudioFrame's worth of audio (before the sequence number is assigned).
public struct AudioPacket: Equatable, Sendable {
    /// Host monotonic µs of the packet's first sample.
    public let captureUs: UInt64
    /// Interleaved s16le.
    public let pcm: Data
    public let frames: Int
}

public enum AudioPCMError: Error, CustomStringConvertible {
    case noFormat
    case unsupported(String)
    case bufferList(OSStatus)

    public var description: String {
        switch self {
        case .noFormat: return "audio sample buffer has no format description"
        case .unsupported(let s): return "unsupported audio format: \(s)"
        case .bufferList(let st): return "CMSampleBufferGetAudioBufferList failed (\(st))"
        }
    }
}

/// Linear PCM -> wire format (interleaved s16le), pure and offline-testable.
public enum AudioPCM {
    /// Float [-1, 1] -> s16, clipped, rounded to nearest (NaN -> 0). Symmetric: ±1.0 -> ±32767.
    @inline(__always)
    public static func s16(_ x: Float) -> Int16 {
        guard x == x else { return 0 }
        let c = min(max(x, -1), 1)
        return Int16((c * 32767).rounded())
    }

    /// Near-equal consecutive ranges of at most `maxFrames` covering `0..<frames`
    /// (e.g. 1024 by 480 -> 342 + 341 + 341), so no tiny trailing packet.
    public static func chunkRanges(frames: Int, maxFrames: Int) -> [Range<Int>] {
        guard frames > 0, maxFrames > 0 else { return [] }
        let n = (frames + maxFrames - 1) / maxFrames
        var out: [Range<Int>] = []
        var start = 0
        for i in 0..<n {
            let len = frames / n + (i < frames % n ? 1 : 0)
            out.append(start ..< start + len)
            start += len
        }
        return out
    }

    /// Interleaves `channels` sample streams into s16le. `sample(ch, frame)` returns a float sample.
    @inline(__always)
    static func interleave(frames: Range<Int>, channels: Int, _ sample: (Int, Int) -> Float) -> Data {
        var d = Data(count: frames.count * channels * 2)
        d.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            var o = 0
            for f in frames {
                for c in 0..<channels {
                    out[o] = s16(sample(c, f)).littleEndian
                    o += 1
                }
            }
        }
        return d
    }

    /// Converts one linear-PCM CMSampleBuffer (float32 or s16, planar or interleaved — what
    /// ScreenCaptureKit delivers is float32 planar) into the wire config + packets of at most
    /// `maxFrames` frames each (default: 10 ms).
    public static func packetize(_ sb: CMSampleBuffer, maxFrames: Int? = nil) throws -> (AudioConfig, [AudioPacket]) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { throw AudioPCMError.noFormat }
        let asbd = asbdP.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let rate = asbd.mSampleRate
        guard asbd.mFormatID == kAudioFormatLinearPCM, channels >= 1, channels <= 8, rate >= 8000, rate <= 192_000 else {
            throw AudioPCMError.unsupported(describe(asbd))
        }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16 && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0),
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            throw AudioPCMError.unsupported(describe(asbd))
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        let maxF = maxFrames ?? max(1, Int(rate) / 100)
        let cfg = AudioConfig(codec: .pcmS16, sampleRate: UInt32(rate), channels: UInt8(channels), frameSamples: UInt16(clamping: maxF))
        guard frames > 0 else { return (cfg, []) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let t0 = pts.isValid ? max(0, CMTimeGetSeconds(pts)) * 1_000_000 : Double(hostTimeMicros())

        // Fetch the AudioBufferList (one buffer per channel when planar).
        var block: CMBlockBuffer?
        var sizeNeeded = 0
        var st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
                                                                          blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard st == noErr else { throw AudioPCMError.bufferList(st) }
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablP = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablP, bufferListSize: sizeNeeded,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { throw AudioPCMError.bufferList(st) }
        let abl = UnsafeMutableAudioBufferListPointer(ablP)
        let bytesPerSample = bits / 8

        // Validate buffer sizes so a malformed buffer can't read out of bounds.
        if planar {
            guard abl.count >= channels else { throw AudioPCMError.unsupported("planar with \(abl.count) buffers for \(channels) ch") }
            for c in 0..<channels where Int(abl[c].mDataByteSize) < frames * bytesPerSample || abl[c].mData == nil {
                throw AudioPCMError.unsupported("short planar buffer")
            }
        } else {
            guard abl.count >= 1, abl[0].mData != nil, Int(abl[0].mDataByteSize) >= frames * channels * bytesPerSample else {
                throw AudioPCMError.unsupported("short interleaved buffer")
            }
        }

        let sample: (Int, Int) -> Float
        if isFloat {
            if planar {
                let ptrs = (0..<channels).map { abl[$0].mData!.assumingMemoryBound(to: Float.self) }
                sample = { c, f in ptrs[c][f] }
            } else {
                let p = abl[0].mData!.assumingMemoryBound(to: Float.self)
                sample = { c, f in p[f * channels + c] }
            }
        } else {
            if planar {
                let ptrs = (0..<channels).map { abl[$0].mData!.assumingMemoryBound(to: Int16.self) }
                sample = { c, f in Float(Int16(littleEndian: ptrs[c][f])) / 32767 }
            } else {
                let p = abl[0].mData!.assumingMemoryBound(to: Int16.self)
                sample = { c, f in Float(Int16(littleEndian: p[f * channels + c])) / 32767 }
            }
        }
        // Keep the retained block buffer alive until the samples are copied.
        let packets = withExtendedLifetime(block) {
            chunkRanges(frames: frames, maxFrames: maxF).map { r in
                AudioPacket(captureUs: UInt64(t0 + Double(r.lowerBound) * 1_000_000 / rate),
                            pcm: interleave(frames: r, channels: channels, sample), frames: r.count)
            }
        }
        return (cfg, packets)
    }

    public static func describe(_ a: AudioStreamBasicDescription) -> String {
        let f = a.mFormatFlags
        let fourcc = String(bytes: withUnsafeBytes(of: a.mFormatID.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(a.mFormatID)"
        return "\(fourcc) \(Int(a.mSampleRate)) Hz \(a.mChannelsPerFrame) ch \(a.mBitsPerChannel)-bit \(f & kAudioFormatFlagIsFloat != 0 ? "float" : "int")\(f & kAudioFormatFlagIsNonInterleaved != 0 ? " planar" : " interleaved")"
    }
}
