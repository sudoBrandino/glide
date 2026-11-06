import CoreMedia
import Foundation
import GlideCore
import VideoToolbox

/// Hardware HEVC/H.264 encoder producing Annex-B access units.
final class VideoEncoder {
    struct Settings: Equatable {
        var width: Int
        var height: Int
        var codec: Codec
        var chroma: Chroma
        var fps: Int
        var bitrate: Int  // bits/s
    }

    typealias Output = (_ annexB: Data, _ keyframe: Bool, _ pts: CMTime, _ encodeMs: Double) -> Void

    let settings: Settings
    private var session: VTCompressionSession?
    private var forceKey = true

    init(_ s: Settings) throws {
        settings = s
        // Low-latency RC measured worse on real 4K desktop content (22 vs 18.5 ms, and ~6x fewer bits per
        // frame -> visibly softer), and ~100 ms with 4:4:4. Default to normal RC; GLIDE_LL=1 opts in.
        let lowLatency = s.chroma == .yuv420 && ProcessInfo.processInfo.environment["GLIDE_LL"] == "1"
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var sess: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(s.width), height: Int32(s.height),
            codecType: s.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &sess)
        guard st == noErr, let sess else { throw NSError(domain: "VideoEncoder", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed \(st)"]) }
        session = sess

        let profile: CFString
        switch (s.codec, s.chroma) {
        case (.hevc, .yuv444): profile = "HEVC_Main444_AutoLevel" as CFString
        case (.hevc, _): profile = kVTProfileLevel_HEVC_Main_AutoLevel
        case (.h264, _): profile = kVTProfileLevel_H264_High_AutoLevel
        }
        func set(_ k: CFString, _ v: CFTypeRef) {
            let r = VTSessionSetProperty(sess, key: k, value: v)
            if r != noErr { log("encoder: property \(k) rejected (\(r))") }
        }
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, s.fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, s.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (s.fps * 3600) as CFNumber)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    func requestKeyframe() { forceKey = true }
    var keyframePending: Bool { forceKey }

    func encode(_ pb: CVPixelBuffer, pts: CMTime, output: @escaping Output) {
        guard let session else { return }
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let t0 = CACurrentMediaTimeCompat()
        let codec = settings.codec
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { status, _, sb in
            let ms = (CACurrentMediaTimeCompat() - t0) * 1000
            guard status == noErr, let sb, CMSampleBufferDataIsReady(sb) else {
                if status != noErr { log("encoder: frame error \(status)") }
                return
            }
            if let (data, key) = VideoEncoder.annexB(sb, codec: codec) {
                output(data, key, pts, ms)
            }
        }
        if st != noErr { log("encoder: EncodeFrame failed \(st)"); forceKey = true }
    }

    /// Converts a length-prefixed (AVCC/HVCC) sample to Annex-B, prepending parameter sets on keyframes.
    static func annexB(_ sb: CMSampleBuffer, codec: Codec) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = atts.first, let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        out.reserveCapacity(CMBlockBufferGetDataLength(block) + 256)
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var nalHeaderLen: Int32 = 0
            if codec == .hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen)
            }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = codec == .hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let ptr { out.append(contentsOf: start); out.append(ptr, count: size) }
            }
        }
        // Walk the 4-byte length-prefixed NAL units.
        var total = 0
        var raw: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &raw) == noErr, let raw else {
            // Non-contiguous block buffer: copy out.
            var tmp = Data(count: CMBlockBufferGetDataLength(block))
            let ok = tmp.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) } == noErr
            guard ok else { return nil }
            return appendNALs(from: tmp, into: &out, start: start) ? (out, isKey) : nil
        }
        let d = Data(bytesNoCopy: raw, count: total, deallocator: .none)
        return appendNALs(from: d, into: &out, start: start) ? (out, isKey) : nil
    }

    private static func appendNALs(from d: Data, into out: inout Data, start: [UInt8]) -> Bool {
        var off = 0
        let n = d.count
        return d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            while off + 4 <= n {
                let len = Int(UInt32(p[off]) << 24 | UInt32(p[off + 1]) << 16 | UInt32(p[off + 2]) << 8 | UInt32(p[off + 3]))
                off += 4
                guard len > 0, off + len <= n else { return false }
                out.append(contentsOf: start)
                out.append(p.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt8.self), count: len)
                off += len
            }
            return true
        }
    }
}

@inline(__always) func CACurrentMediaTimeCompat() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

func log(_ s: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write(Data("[\(ts)] \(s)\n".utf8))
}
