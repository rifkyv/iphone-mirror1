import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncoderSettings: Equatable {
    var hevc: Bool
    var bitrate: Int
    var fps: Int
    var maxLongSide: Int
    var keyframeInterval: Double
}

/// Hardware H.264 / HEVC encoder tuned for low latency, with our own bitrate.
/// Output is Annex-B (start codes), with parameter sets in front of every keyframe.
final class VideoEncoder {
    let width: Int32
    let height: Int32
    let settings: EncoderSettings

    /// (annexB, isKeyframe, ptsMicroseconds, tag)
    var onOutput: ((Data, Bool, UInt64, UInt8) -> Void)?

    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var forceKeyframe = true
    private var nalLengthSize = 4
    private let startCode: [UInt8] = [0, 0, 0, 1]

    init?(sourceWidth: Int, sourceHeight: Int, settings: EncoderSettings) {
        let longSide = max(sourceWidth, sourceHeight)
        var scale = 1.0
        if settings.maxLongSide > 0 && longSide > settings.maxLongSide {
            scale = Double(settings.maxLongSide) / Double(longSide)
        }
        let w = Int32((Double(sourceWidth) * scale / 2.0).rounded()) * 2
        let h = Int32((Double(sourceHeight) * scale / 2.0).rounded()) * 2
        self.width = max(w, 16)
        self.height = max(h, 16)
        self.settings = settings
        if !setUp() {
            return nil
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        transfer = nil
        pool = nil
    }

    func requestKeyframe() {
        forceKeyframe = true
    }

    // MARK: - setup

    private func setUp() -> Bool {
        var created: VTCompressionSession?
        let codec: CMVideoCodecType = settings.hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            return false
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        if settings.hevc {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: settings.bitrate))
        let bytesPerSecond = Double(settings.bitrate) / 8.0 * 1.5
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.fps))
        let keyframeFrames = max(1, Int(Double(settings.fps) * settings.keyframeInterval))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeFrames))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: settings.keyframeInterval))
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)

        // Scale + convert to video-range BT.709 on the GPU before encoding.
        var createdTransfer: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &createdTransfer) == noErr,
           let transfer = createdTransfer {
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            self.transfer = transfer

            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(width),
                kCVPixelBufferHeightKey as String: Int(height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var createdPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool)
            self.pool = createdPool
        }
        return true
    }

    // MARK: - encoding

    func encode(_ source: CVPixelBuffer, pts: CMTime, tag: UInt8) {
        guard let session = session else { return }

        var input = source
        if let transfer = transfer, let pool = pool {
            var converted: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &converted) == kCVReturnSuccess,
               let destination = converted,
               VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr {
                input = destination
            }
        }

        var frameProperties: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let seconds = CMTimeGetSeconds(pts)
        let ptsMicros: UInt64 = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000) : 0

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: input,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let self = self else { return }
            self.handleOutput(sampleBuffer, ptsMicros: ptsMicros, tag: tag)
        }
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer, ptsMicros: UInt64, tag: UInt8) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var out = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSets(format, to: &out)
        }

        let total = CMBlockBufferGetDataLength(dataBuffer)
        guard total > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: total, destination: &bytes) == kCMBlockBufferNoErr else {
            return
        }

        let lengthSize = nalLengthSize
        var offset = 0
        while offset + lengthSize <= total {
            var nalLength = 0
            for k in 0..<lengthSize {
                nalLength = (nalLength << 8) | Int(bytes[offset + k])
            }
            offset += lengthSize
            if nalLength <= 0 || offset + nalLength > total { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        onOutput?(out, isKeyframe, ptsMicros, tag)
    }

    private func appendParameterSets(_ format: CMFormatDescription, to out: inout Data) {
        var count = 0
        var headerLength: Int32 = 4
        let countStatus: OSStatus
        if settings.hevc {
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        } else {
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        }
        guard countStatus == noErr else { return }
        if headerLength > 0 && headerLength <= 4 {
            nalLengthSize = Int(headerLength)
        }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if settings.hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if status == noErr, let pointer = pointer, size > 0 {
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
    }
}
