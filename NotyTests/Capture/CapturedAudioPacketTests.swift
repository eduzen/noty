import AudioToolbox
import CoreMedia
import Foundation
@testable import Noty
import XCTest

final class CapturedAudioPacketTests: XCTestCase {
    func testCopiesNativeInt16MicrophoneSamplesAsFloat32() throws {
        let buffer = try sampleBuffer(
            samples: [Int16.min, -16384, 0, Int16.max],
            channels: 2,
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        )

        let packet = try XCTUnwrap(CapturedAudioPacket.copying(buffer, source: .microphone))

        XCTAssertEqual(packet.source, .microphone)
        XCTAssertEqual(packet.presentationTime, 1.25)
        XCTAssertEqual(packet.sampleRate, 48000)
        XCTAssertEqual(packet.channelCount, 2)
        XCTAssertEqual(packet.frameCount, 2)
        XCTAssertEqual(packet.samples, [-1, -0.5, 0, Float(Int16.max) / 32768])
    }

    func testInterleavesPlanarFloat32SystemAudio() throws {
        let buffer = try sampleBuffer(
            samples: [Float(0.25), 0.75, -0.5, -1],
            channels: 2,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        )

        let packet = try XCTUnwrap(CapturedAudioPacket.copying(buffer, source: .system))

        XCTAssertEqual(packet.source, .system)
        XCTAssertEqual(packet.samples, [0.25, -0.5, 0.75, -1])
    }

    func testInterleavesPlanarInt16MicrophoneAudio() throws {
        let buffer = try sampleBuffer(
            samples: [Int16.min, 0, -16384, Int16.max],
            channels: 2,
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        )

        let packet = try XCTUnwrap(CapturedAudioPacket.copying(buffer, source: .microphone))

        XCTAssertEqual(packet.samples, [-1, -0.5, 0, Float(Int16.max) / 32768])
    }

    func testRejectsUnsignedPCMInsteadOfInterpretingItAsSigned() throws {
        let buffer = try sampleBuffer(
            samples: [UInt16(0), UInt16.max],
            channels: 1,
            flags: kAudioFormatFlagIsPacked
        )

        XCTAssertThrowsError(try CapturedAudioPacket.copying(buffer, source: .microphone)) { error in
            XCTAssertEqual(error as? CaptureServiceError, .invalidAudioFormat)
        }
    }

    private func sampleBuffer<Sample>(
        samples: [Sample],
        channels: Int,
        flags: AudioFormatFlags
    ) throws -> CMSampleBuffer {
        let sampleBytes = MemoryLayout<Sample>.size
        let bytesPerFrame = sampleBytes * (flags & kAudioFormatFlagIsNonInterleaved == 0 ? channels : 1)
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(sampleBytes * 8),
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ), noErr)
        let audioFormat = try XCTUnwrap(format)

        let byteCount = samples.count * sampleBytes
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ), noErr)
        let dataBlock = try XCTUnwrap(block)
        try samples.withUnsafeBytes { bytes in
            let data = try XCTUnwrap(bytes.baseAddress)
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(
                with: data,
                blockBuffer: dataBlock,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ), noErr)
        }

        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBlock,
            formatDescription: audioFormat,
            sampleCount: samples.count / channels,
            presentationTimeStamp: CMTime(value: 5, timescale: 4),
            packetDescriptions: nil,
            sampleBufferOut: &buffer
        ), noErr)
        return try XCTUnwrap(buffer)
    }
}
