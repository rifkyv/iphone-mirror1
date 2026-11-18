import AudioToolbox
import CoreMedia
import Foundation

/// Turns a ReplayKit app-audio sample buffer into the AUDIO payload of the wire protocol:
/// sample_rate u32 BE, channels u8, bits u8, flags u8 (bit0 float, bit1 big endian), reserved u8,
/// then interleaved PCM in the original sample format. The PC converts it.
enum AudioPacker {
    static func pack(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerSample = bits / 8
        guard bytesPerSample > 0 else { return nil }

        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let list = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0 else { return nil }

        let channels: Int
        let pcm: Data
        if !nonInterleaved || buffers.count == 1 {
            let buffer = buffers[0]
            guard let source = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
            channels = nonInterleaved ? 1 : Int(max(1, asbd.mChannelsPerFrame))
            pcm = Data(bytes: source, count: Int(buffer.mDataByteSize))
        } else {
            // Planar: interleave the channels.
            channels = buffers.count
            let frames = Int(buffers[0].mDataByteSize) / bytesPerSample
            guard frames > 0 else { return nil }
            var interleaved = [UInt8](repeating: 0, count: frames * channels * bytesPerSample)
            for (channelIndex, buffer) in buffers.enumerated() {
                guard let source = buffer.mData?.assumingMemoryBound(to: UInt8.self) else { continue }
                let available = Int(buffer.mDataByteSize) / bytesPerSample
                for frame in 0..<min(frames, available) {
                    let destination = (frame * channels + channelIndex) * bytesPerSample
                    let origin = frame * bytesPerSample
                    for byte in 0..<bytesPerSample {
                        interleaved[destination + byte] = source[origin + byte]
                    }
                }
            }
            pcm = Data(interleaved)
        }
        _ = blockBuffer  // keep the block buffer alive until the copy above is done

        var header = Data(capacity: 8)
        var rate = UInt32(max(1, asbd.mSampleRate.rounded())).bigEndian
        withUnsafeBytes(of: &rate) { header.append(contentsOf: $0) }
        header.append(UInt8(clamping: channels))
        header.append(UInt8(clamping: bits))
        let flags: UInt8 = (isFloat ? 1 : 0) | (isBigEndian ? 2 : 0)
        header.append(flags)
        header.append(UInt8(0))
        header.append(pcm)
        return header
    }
}
