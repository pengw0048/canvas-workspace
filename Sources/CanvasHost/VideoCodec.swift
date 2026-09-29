import AppKit
import CoreImage
import VideoToolbox

/// One encoded H.264 frame as sent on the wire: parameter sets travel with every keyframe.
struct VideoPacket {
    var keyframe: Bool
    var width: Int
    var height: Int
    var parameterSets: [Data]
    var sample: Data  // AVCC: 4-byte big-endian length before each NAL unit

    /// [u8 count][u32 len, bytes]... then the sample.
    func payload() -> Data {
        var d = Data([UInt8(parameterSets.count)])
        for p in parameterSets { d.append(contentsOf: withUnsafeBytes(of: UInt32(p.count).bigEndian, Array.init)); d.append(p) }
        d.append(sample)
        return d
    }

    init(keyframe: Bool, width: Int, height: Int, parameterSets: [Data], sample: Data) {
        self.keyframe = keyframe; self.width = width; self.height = height; self.parameterSets = parameterSets; self.sample = sample
    }

    init?(header: [String: String], payload d: Data) {
        guard let w = Int(header["w"] ?? ""), let h = Int(header["h"] ?? ""), !d.isEmpty else { return nil }
        let b = [UInt8](d)
        var i = 1
        var sets: [Data] = []
        for _ in 0..<Int(b[0]) {
            guard i + 4 <= b.count else { return nil }
            let n = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
            i += 4
            guard i + n <= b.count else { return nil }
            sets.append(Data(b[i..<(i + n)]))
            i += n
        }
        self.init(keyframe: header["k"] == "1", width: w, height: h, parameterSets: sets, sample: Data(b[i...]))
    }
}

/// Hardware H.264 for live window streams: real time, no frame reordering, adjustable bitrate, keyframes on request.
final class H264Encoder {
    private var session: VTCompressionSession?
    private var size = (0, 0)
    private var forceKey = true
    private(set) var bitrate: Int
    let maxBitrate: Int
    var onPacket: ((VideoPacket) -> Void)?

    init(maxBitrate: Int = 6_000_000) {
        self.maxBitrate = maxBitrate
        bitrate = maxBitrate / 2
    }

    deinit { if let s = session { VTCompressionSessionInvalidate(s) } }

    func requestKeyframe() { forceKey = true }

    /// Congestion lowers the rate quickly; a clear path raises it slowly.
    func adapt(congested: Bool) {
        bitrate = congested ? max(300_000, Int(Double(bitrate) * 0.7)) : min(maxBitrate, Int(Double(bitrate) * 1.1))
        if let s = session { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) }
    }

    func encode(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if session == nil || size != (w, h) { makeSession(w, h) }
        guard let s = session else { return }
        let t = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        let opts = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKey = false
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: t, duration: .invalid, frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb, w, h)
        }
    }

    private func makeSession(_ w: Int, _ h: Int) {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr,
              let s else { return }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        size = (w, h)
        forceKey = true
    }

    private func emit(_ sb: CMSampleBuffer, _ w: Int, _ h: Int) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var sets: [Data] = []
        if key, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    sets.append(Data(bytes: p, count: n))
                }
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { return }
        let packet = VideoPacket(keyframe: key, width: w, height: h, parameterSets: sets, sample: Data(bytes: ptr, count: len))
        DispatchQueue.main.async { self.onPacket?(packet) }
    }
}

/// Hardware H.264 decoding into IOSurface-backed buffers that layers display directly.
final class H264Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Asks the sender for a keyframe (first frame, a new size, or a decode failure).
    var onNeedKeyframe: (() -> Void)?
    private var waitingForKey = true

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    func decode(_ p: VideoPacket) {
        if p.keyframe, !p.parameterSets.isEmpty { configure(p.parameterSets) }
        if waitingForKey && !p.keyframe { onNeedKeyframe?(); return }
        guard let s = session, let format else { onNeedKeyframe?(); return }
        var bb: CMBlockBuffer?
        let bytes = [UInt8](p.sample)
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &bb) == noErr, let bb,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes.count) }) == noErr else { return }
        var sb: CMSampleBuffer?
        var sizes = [bytes.count]
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr, let sb else { return }
        let status = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if status == noErr, let image { self.onFrame?(image) } else { self.waitingForKey = true; self.onNeedKeyframe?() }
            }
        }
        if status == noErr { waitingForKey = false } else { waitingForKey = true; onNeedKeyframe?() }
    }

    private func configure(_ sets: [Data]) {
        var fmt: CMVideoFormatDescription?
        let arrays = sets.map { [UInt8]($0) }
        let status: OSStatus = arrays[0].withUnsafeBufferPointer { a0 -> OSStatus in
            arrays.count > 1 ? arrays[1].withUnsafeBufferPointer { a1 -> OSStatus in
                var ptrs = [a0.baseAddress!, a1.baseAddress!]
                var sizes = [arrays[0].count, arrays[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                                                                          nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            } : -1
        }
        guard status == noErr, let fmt else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: fmt), session != nil { return }
        if let s = session { VTDecompressionSessionInvalidate(s) }
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &s) == noErr else { return }
        VTSessionSetProperty(s!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
    }
}

/// Still images (browser snapshots) as pixel buffers the encoder accepts, flattened onto white.
enum PixelBuffers {
    static func make(from img: CGImage, maxSide: Int = 1920) -> CVPixelBuffer? {
        let s = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = Int(Double(img.width) * s) & ~1, h = Int(Double(img.height) * s) & ~1
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary
        guard w > 0, h > 0, CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
