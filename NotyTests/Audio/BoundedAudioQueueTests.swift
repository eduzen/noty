import XCTest
@testable import Noty

final class BoundedAudioQueueTests: XCTestCase {
    func testDequeuePreservesOrderAndReleasesCapacity() throws {
        var queue = BoundedAudioQueue(maximumDuration: 1, maximumCopiedBytes: 64)
        let first = chunk(time: 0, frames: 2, value: 0.1)
        let second = chunk(time: 2.0 / 48_000, frames: 2, value: 0.2)
        try queue.enqueue(first)
        try queue.enqueue(second)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.copiedBytes, 32)
        XCTAssertEqual(queue.dequeue()?.presentationTime, first.presentationTime)
        XCTAssertEqual(queue.dequeue()?.presentationTime, second.presentationTime)
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.copiedBytes, 0)
        XCTAssertEqual(queue.queuedDuration, 0, accuracy: 0.000001)
    }

    func testFailsBeforeExceedingCopiedByteLimit() throws {
        var queue = BoundedAudioQueue(maximumDuration: 5, maximumCopiedBytes: 16)
        try queue.enqueue(chunk(time: 0, frames: 2, value: 0.25))
        XCTAssertThrowsError(try queue.enqueue(chunk(time: 2.0 / 48_000, frames: 1, value: 0.5))) { error in
            XCTAssertEqual(error as? AudioPipelineError, .queueOverflow)
        }
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.copiedBytes, 16)
    }

    func testFailsBeforeExceedingDurationLimit() throws {
        var queue = BoundedAudioQueue(maximumDuration: 0.1, maximumCopiedBytes: 64 * 1_024)
        try queue.enqueue(chunk(time: 0, frames: 4_800, value: 0.1))
        XCTAssertThrowsError(try queue.enqueue(chunk(time: 0.1, frames: 1, value: 0.2))) { error in
            XCTAssertEqual(error as? AudioPipelineError, .queueOverflow)
        }
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.queuedDuration, 0.1, accuracy: 0.000001)
    }

    func testDefaultQueueRejectsBeyondFiveSeconds() throws {
        var queue = BoundedAudioQueue()
        try queue.enqueue(chunk(time: 0, frames: 240_000, value: 0.1))
        XCTAssertThrowsError(try queue.enqueue(chunk(time: 5, frames: 1, value: 0.2)))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.queuedDuration, 5, accuracy: 0.000001)
    }

    private func chunk(time: Double, frames: Int, value: Float) -> MixedAudioChunk {
        MixedAudioChunk(presentationTime: time, frameCount: frames,
                        samples: Array(repeating: [value, value], count: frames).flatMap { $0 })
    }
}
