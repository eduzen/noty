import Foundation

struct BoundedAudioQueue {
    enum OverflowPolicy: Equatable, Sendable {
        case failOnOverflow
    }

    private let maximumDuration: TimeInterval
    private let maximumCopiedBytes: Int
    private let overflowPolicy: OverflowPolicy
    private var storage: [MixedAudioChunk?] = []
    private var head = 0
    private(set) var queuedDuration: TimeInterval = 0
    private(set) var copiedBytes = 0

    init(
        maximumDuration: TimeInterval = 5,
        maximumCopiedBytes: Int = 64 * 1024 * 1024,
        overflowPolicy: OverflowPolicy = .failOnOverflow
    ) {
        self.maximumDuration = max(0, maximumDuration)
        self.maximumCopiedBytes = max(0, maximumCopiedBytes)
        self.overflowPolicy = overflowPolicy
    }

    var count: Int {
        storage.count - head
    }

    var isEmpty: Bool {
        count == 0
    }

    mutating func enqueue(_ chunk: MixedAudioChunk) throws {
        let bytes = chunk.samples.count * MemoryLayout<Float>.size
        let duration = Double(chunk.frameCount) / chunk.sampleRate
        guard chunk.frameCount > 0, chunk.channelCount == AudioFormat.channelCount,
              chunk.frameCount <= Int.max / chunk.channelCount,
              chunk.sampleRate.isFinite, chunk.sampleRate == AudioFormat.sampleRate,
              chunk.samples.count == chunk.frameCount * chunk.channelCount,
              duration.isFinite, duration <= maximumDuration, bytes <= maximumCopiedBytes,
              queuedDuration + duration <= maximumDuration,
              copiedBytes + bytes <= maximumCopiedBytes
        else {
            if overflowPolicy == .failOnOverflow {
                throw AudioPipelineError.queueOverflow
            }
            return
        }
        storage.append(chunk)
        queuedDuration += duration
        copiedBytes += bytes
    }

    mutating func dequeue() -> MixedAudioChunk? {
        guard head < storage.count, let chunk = storage[head] else { return nil }
        storage[head] = nil
        head += 1
        queuedDuration -= Double(chunk.frameCount) / chunk.sampleRate
        copiedBytes -= chunk.samples.count * MemoryLayout<Float>.size
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return chunk
    }
}
