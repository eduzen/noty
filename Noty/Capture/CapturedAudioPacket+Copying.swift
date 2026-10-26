import AudioToolbox
import CoreMedia
import Foundation

extension CapturedAudioPacket {
    /// Largest packet accepted from a capture callback, in bytes of Float32 samples.
    private static let maximumPacketBytes = 64 * 1024 * 1024 / 5

    /// Copies a CoreMedia sample buffer into a packet. Used by tests that cover the format rules.
    static func copying(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws -> CapturedAudioPacket? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { throw CaptureServiceError.invalidAudioFormat }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric else { throw CaptureServiceError.invalidAudioFormat }

        var needed = 0
        var retainedBlock: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr, needed > 0, needed <= 4096 else { throw CaptureServiceError.invalidAudioFormat }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: needed,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { throw CaptureServiceError.invalidAudioFormat }
        // The block buffer owns the samples that `list` points at, so keep it alive for the copy.
        return try withExtendedLifetime(retainedBlock) {
            try copying(
                bufferList: UnsafePointer(list),
                format: format,
                source: source,
                presentationTime: CMTimeGetSeconds(time)
            )
        }
    }

    /// Validates a PCM buffer list described by `format` and copies it into interleaved Float32 samples.
    ///
    /// Used by every capture path. Unsupported layouts throw instead of producing silence.
    static func copying(
        bufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        source: AudioSource,
        presentationTime: TimeInterval
    ) throws -> CapturedAudioPacket {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mSampleRate.isFinite,
              format.mSampleRate > 0,
              presentationTime.isFinite
        else { throw CaptureServiceError.invalidAudioFormat }
        let isFloat32 = format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInt16 = format.mBitsPerChannel == 16
            && format.mFormatFlags & kAudioFormatFlagIsFloat == 0
            && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard isFloat32 || isSignedInt16 else { throw CaptureServiceError.invalidAudioFormat }
        let bytesPerSample = isFloat32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let channels = Int(format.mChannelsPerFrame)
        guard channels > 0, channels <= 8 else { throw CaptureServiceError.invalidAudioFormat }
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        // Non-interleaved buffers hold one channel each, so each frame is one sample per buffer.
        let bytesPerFrame = isNonInterleaved ? bytesPerSample : channels * bytesPerSample
        guard format.mBytesPerFrame == UInt32(bytesPerFrame) else { throw CaptureServiceError.invalidAudioFormat }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, first.mDataByteSize > 0 else {
            throw CaptureServiceError.invalidAudioFormat
        }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0 else { throw CaptureServiceError.invalidAudioFormat }
        let sampleCount = frames * channels
        guard sampleCount * MemoryLayout<Float>.size <= maximumPacketBytes,
              Double(frames) / format.mSampleRate <= 1.0
        else { throw CaptureServiceError.queueOverflow }

        let bytesPerPlane = frames * bytesPerSample
        if buffers.count == 1, buffers[0].mNumberChannels == UInt32(channels) {
            guard Int(buffers[0].mDataByteSize) >= sampleCount * bytesPerSample, buffers[0].mData != nil else {
                throw CaptureServiceError.invalidAudioFormat
            }
        } else {
            guard buffers.count == channels,
                  buffers.allSatisfy({ buffer in
                      buffer.mNumberChannels == 1 && Int(buffer.mDataByteSize) >= bytesPerPlane && buffer.mData != nil
                  })
            else {
                throw CaptureServiceError.invalidAudioFormat
            }
        }

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        if isFloat32 {
            if buffers.count == 1 {
                let data = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: sampleCount))
            } else {
                for frame in 0 ..< frames {
                    for buffer in buffers {
                        let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                        samples.append(data[frame])
                    }
                }
            }
        } else if buffers.count == 1 {
            let data = buffers[0].mData!.assumingMemoryBound(to: Int16.self)
            for sample in UnsafeBufferPointer(start: data, count: sampleCount) {
                samples.append(Float(sample) / 32768)
            }
        } else {
            for frame in 0 ..< frames {
                for buffer in buffers {
                    let data = buffer.mData!.assumingMemoryBound(to: Int16.self)
                    samples.append(Float(data[frame]) / 32768)
                }
            }
        }

        return CapturedAudioPacket(
            source: source,
            presentationTime: presentationTime,
            sampleRate: format.mSampleRate,
            channelCount: channels,
            frameCount: frames,
            samples: samples
        )
    }
}
