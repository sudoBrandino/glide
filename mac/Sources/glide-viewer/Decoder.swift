import CoreMedia
import CoreVideo
import Foundation
import GlideCore
import VideoToolbox

/// VideoToolbox decoder for the host's Annex-B HEVC / H.264 stream (PROTOCOL.md §3: parameter
/// sets in-band on keyframes, 4-byte start codes, no B-frames). Same approach as glide-probe.
/// Not thread-safe: call from one queue.
final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: Codec = .hevc

    /// A decoded frame (called on a VideoToolbox thread).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// A frame couldn't be decoded (or arrived before any parameter sets): ask for a keyframe.
    var onError: ((String) -> Void)?

    func reset(codec: Codec) {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
        self.codec = codec
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    /// NAL units of an Annex-B stream (3- or 4-byte start codes).
    static func splitAnnexB(_ d: Data) -> [Data] {
        var nals: [Data] = []
        let b = [UInt8](d)
        var i = 0, start = -1
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 || (i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1) {
                let scLen = b[i + 2] == 1 ? 3 : 4
                if start >= 0 { nals.append(Data(b[start ..< i])) }
                i += scLen
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < b.count { nals.append(Data(b[start...])) }
        return nals
    }

    private func nalType(_ n: Data) -> Int {
        let h = n[n.startIndex]
        return codec == .hevc ? Int((h >> 1) & 0x3F) : Int(h & 0x1F)
    }

    func decode(_ annexB: Data) {
        var params: [Data] = [], slices: [Data] = []
        for n in VideoDecoder.splitAnnexB(annexB) where !n.isEmpty {
            let t = nalType(n)
            let isParam = codec == .hevc ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8)
            let isAUD = codec == .hevc ? t == 35 : t == 9
            if isParam { params.append(n) } else if !isAUD { slices.append(n) }
        }
        if !params.isEmpty { updateFormat(params) }
        guard !slices.isEmpty else { return }
        guard let session, let format else { onError?("frame before parameter sets"); return }

        var avcc = Data()
        for s in slices {
            var be = UInt32(s.count).bigEndian
            withUnsafeBytes(of: &be) { avcc.append(contentsOf: $0) }
            avcc.append(s)
        }
        guard let mem = malloc(avcc.count) else { return }
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: mem, blockLength: avcc.count, blockAllocator: kCFAllocatorMalloc,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else { free(mem); onError?("CMBlockBuffer \(st)"); return }
        var sb: CMSampleBuffer?
        var size = avcc.count
        st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                       sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let sb else { onError?("CMSampleBuffer \(st)"); return }
        let handler = onFrame, errHandler = onError
        st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            guard status == noErr, let img else { errHandler?("decode status \(status)"); return }
            handler?(img)
        }
        if st != noErr { onError?("decode submit \(st)") }
    }

    private func updateFormat(_ params: [Data]) {
        var fd: CMFormatDescription?
        let ptrs = params.map { p -> UnsafePointer<UInt8> in
            let m = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count)
            p.copyBytes(to: m, count: p.count)
            return UnsafePointer(m)
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let sizes = params.map { $0.count }
        let st = codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { onError?("bad parameter sets (\(st))"); return }
        if let old = format, session != nil, CMFormatDescriptionEqual(fd, otherFormatDescription: old) { return }
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = fd
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var s: VTDecompressionSession?
        let cst = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                               outputCallback: nil, decompressionSessionOut: &s)
        guard cst == noErr, let s else { onError?("VTDecompressionSessionCreate \(cst)"); return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
    }
}
