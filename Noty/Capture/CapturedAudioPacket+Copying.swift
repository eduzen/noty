import AudioToolbox
import CoreMedia
import Foundation

extension CapturedAudioPacket {
    private struct FormatDetails {
        let channels: Int
        let isFloat32: Bool
        let bytesPerSample: Int
        let bytesPerFrame: Int
    }

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
        let details = try formatDetails(for: format, presentationTime: presentationTime)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let frames = try validateBuffers(buffers, details: details, sampleRate: format.mSampleRate)
        let samples = copySamples(from: buffers, frames: frames, details: details)
        return CapturedAudioPacket(
            source: source,
            presentationTime: presentationTime,
            sampleRate: format.mSampleRate,
            channelCount: details.channels,
            frameCount: frames,
            samples: samples
        )
    }

    private static func formatDetails(
        for format: AudioStreamBasicDescription,
        presentationTime: TimeInterval
    ) throws -> FormatDetails {
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
        let bytesPerFrame = isNonInterleaved ? bytesPerSample : channels * bytesPerSample
        guard format.mBytesPerFrame == UInt32(bytesPerFrame) else { throw CaptureServiceError.invalidAudioFormat }
        return FormatDetails(
            channels: channels,
            isFloat32: isFloat32,
            bytesPerSample: bytesPerSample,
            bytesPerFrame: bytesPerFrame
        )
    }

    private static func validateBuffers(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        details: FormatDetails,
        sampleRate: Double
    ) throws -> Int {
        guard let first = buffers.first, first.mDataByteSize > 0 else {
            throw CaptureServiceError.invalidAudioFormat
        }
        let frames = Int(first.mDataByteSize) / details.bytesPerFrame
        guard frames > 0 else { throw CaptureServiceError.invalidAudioFormat }
        let sampleCount = frames * details.channels
        guard sampleCount * MemoryLayout<Float>.size <= maximumPacketBytes,
              Double(frames) / sampleRate <= 1.0
        else { throw CaptureServiceError.queueOverflow }

        let bytesPerPlane = frames * details.bytesPerSample
        if buffers.count == 1, buffers[0].mNumberChannels == UInt32(details.channels) {
            guard Int(buffers[0].mDataByteSize) >= sampleCount * details.bytesPerSample,
                  buffers[0].mData != nil else {
                throw CaptureServiceError.invalidAudioFormat
            }
        } else {
            guard buffers.count == details.channels,
                  buffers.allSatisfy({ buffer in
                      buffer.mNumberChannels == 1 && Int(buffer.mDataByteSize) >= bytesPerPlane && buffer.mData != nil
                  })
            else {
                throw CaptureServiceError.invalidAudioFormat
            }
        }
        return frames
    }

    private static func copySamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        details: FormatDetails
    ) -> [Float] {
        let sampleCount = frames * details.channels
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        if details.isFloat32 {
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
        return samples
    }
}
