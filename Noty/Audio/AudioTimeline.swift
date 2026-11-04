import Foundation

/// PTS-ordered accumulator. Packets may arrive up to `reorderWindow` late; later overlap is trimmed.
struct AudioTimeline: Sendable {
    private static let maximumBufferedFrames = 5 * 48000
    private static let maximumBufferedBytes = 64 * 1024 * 1024

    private let reorderWindow: TimeInterval
    private let configuredOrigin: TimeInterval?
    private var origin: TimeInterval?
    private var outputOrigin: TimeInterval?
    private var cursorFrame: Int64 = 0
    private var latestEnd: TimeInterval?
    private var pending: [NormalizedAudioPacket] = []
    private var pendingBytes = 0

    init(origin: TimeInterval? = nil, reorderWindow: TimeInterval = 0.25) {
        configuredOrigin = origin
        self.origin = origin
        outputOrigin = origin
        self.reorderWindow = max(0, reorderWindow)
    }

    mutating func append(_ packet: NormalizedAudioPacket) throws -> [MixedAudioChunk] {
        let packetEnd = try validatedEnd(of: packet)
        if origin == nil {
            origin = packet.presentationTime
            outputOrigin = packet.presentationTime
        }
        let timelineOrigin = packet.isDiscontinuity && latestEnd != nil ? packet.presentationTime : origin!
        let relativeFrame = (packet.presentationTime - timelineOrigin) * AudioFormat.sampleRate
        let relativeEndFrame = (packetEnd - timelineOrigin) * AudioFormat.sampleRate
        guard packetEnd.isFinite, relativeFrame.isFinite, relativeEndFrame.isFinite,
              abs(relativeFrame) < Double(Int64.max) - Double(packet.frameCount),
              abs(relativeEndFrame) < Double(Int64.max)
        else {
            throw AudioPipelineError.timingDiscontinuity("Audio timestamps exceed the supported output timeline.")
        }

        var chunks: [MixedAudioChunk] = []
        if let previousEnd = latestEnd, packet.isDiscontinuity {
            try chunks.append(contentsOf: render(through: frame(at: previousEnd)))
            let continuedOutputOrigin = (outputOrigin ?? previousEnd) + Double(cursorFrame) / AudioFormat.sampleRate
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            origin = packet.presentationTime
            outputOrigin = continuedOutputOrigin
            cursorFrame = 0
            latestEnd = nil
        }
        if configuredOrigin == nil, cursorFrame == 0, packet.presentationTime < origin! {
            let shift = packet.presentationTime - origin!
            origin = packet.presentationTime
            outputOrigin = (outputOrigin ?? origin!) + shift
        }
        // #region agent log
        if frame(at: packetEnd) <= cursorFrame, AgentDebugLog.shouldEmit(
            "timeline.drop.\(packet.source.rawValue)",
            interval: 1
        ) {
            AgentDebugLog.log("AudioTimeline.append", "packet dropped as late", hypothesis: "C,D", [
                "source": packet.source.rawValue, "lateByFrames": cursorFrame - frame(at: packetEnd),
                "pts": packet.presentationTime, "latestEnd": latestEnd ?? -1, "frames": packet.frameCount
            ])
        }
        // #endregion
        guard frame(at: packetEnd) > cursorFrame else { return chunks }

        let nextBytes = try pendingByteCount(after: packet, endingAt: packetEnd)
        latestEnd = max(latestEnd ?? packetEnd, packetEnd)
        pending.append(packet)
        pendingBytes = nextBytes
        pending.sort(by: Self.packetOrder)
        let watermark = max(origin!, latestEnd! - reorderWindow)
        try chunks.append(contentsOf: render(through: frame(at: watermark)))
        return chunks
    }

    mutating func finish(through endTime: TimeInterval? = nil) throws -> [MixedAudioChunk] {
        guard let latestEnd else { return [] }
        if let endTime, !endTime.isFinite || endTime < 0 {
            throw AudioPipelineError.malformedPacket("The requested timeline end is invalid.")
        }
        let finalEnd = max(latestEnd, endTime ?? latestEnd)
        let finalFrames = (finalEnd - (origin ?? finalEnd)) * AudioFormat.sampleRate
        guard finalFrames.isFinite, abs(finalFrames) < Double(Int64.max) else {
            throw AudioPipelineError.timingDiscontinuity("Audio timestamps exceed the supported output timeline.")
        }
        pending.sort(by: Self.packetOrder)
        return try render(through: frame(at: finalEnd))
    }

    /// Renders everything buffered so far without ending the timeline. Used when pausing so the audio
    /// before the pause is written; later packets continue from the same cursor.
    mutating func flush() throws -> [MixedAudioChunk] {
        guard let latestEnd else { return [] }
        pending.sort(by: Self.packetOrder)
        return try render(through: frame(at: latestEnd))
    }

    private func pendingByteCount(after packet: NormalizedAudioPacket, endingAt packetEnd: TimeInterval) throws -> Int {
        let packetBytes = packet.samples.count * MemoryLayout<Float>.size
        let nextBytes = pendingBytes.addingReportingOverflow(packetBytes)
        var pendingStart = packet.presentationTime
        var pendingEnd = packetEnd
        for buffered in pending {
            pendingStart = min(pendingStart, buffered.presentationTime)
            pendingEnd = max(
                pendingEnd,
                buffered.presentationTime + Double(buffered.frameCount) / AudioFormat.sampleRate
            )
        }
        let pendingDuration = (pendingEnd - pendingStart) * AudioFormat.sampleRate
        guard !nextBytes.overflow, nextBytes.partialValue <= Self.maximumBufferedBytes,
              pendingDuration.isFinite, pendingDuration <= Double(Self.maximumBufferedFrames)
        else {
            throw AudioPipelineError.queueOverflow
        }
        return nextBytes.partialValue
    }

    private func validatedEnd(of packet: NormalizedAudioPacket) throws -> TimeInterval {
        guard packet.presentationTime.isFinite, packet.presentationTime >= 0,
              packet.frameCount > 0, packet.frameCount <= Int.max / AudioFormat.channelCount,
              packet.samples.count == packet.frameCount * AudioFormat.channelCount,
              packet.samples.allSatisfy(\.isFinite)
        else {
            throw AudioPipelineError.malformedPacket("Normalized packet has invalid timing or sample count.")
        }
        return packet.presentationTime + Double(packet.frameCount) / AudioFormat.sampleRate
    }

    private static func packetOrder(_ lhs: NormalizedAudioPacket, _ rhs: NormalizedAudioPacket) -> Bool {
        if lhs.presentationTime != rhs.presentationTime {
            return lhs.presentationTime < rhs.presentationTime
        }
        if lhs.source != rhs.source {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        if lhs.frameCount != rhs.frameCount {
            return lhs.frameCount > rhs.frameCount
        }
        return lhs.samples.lexicographicallyPrecedes(rhs.samples)
    }

    private func frame(at time: TimeInterval) -> Int64 {
        Int64(((time - (origin ?? time)) * AudioFormat.sampleRate).rounded())
    }

    private mutating func render(through targetFrame: Int64) throws -> [MixedAudioChunk] {
        guard targetFrame > cursorFrame, let origin else { return [] }
        guard targetFrame - cursorFrame <= Int64(Self.maximumBufferedFrames) else {
            throw AudioPipelineError.queueOverflow
        }
        var result: [MixedAudioChunk] = []
        while cursorFrame < targetFrame {
            let count = Int(min(4096, targetFrame - cursorFrame))
            var mix = [Float](repeating: 0, count: count * AudioFormat.channelCount)
            var occupied = [Bool](repeating: false, count: count * AudioFormat.channelCount)
            let intervalStart = cursorFrame
            let intervalEnd = cursorFrame + Int64(count)
            for packet in pending {
                let start = Int64(((packet.presentationTime - origin) * AudioFormat.sampleRate).rounded())
                let end = start + Int64(packet.frameCount)
                let overlapStart = max(intervalStart, start)
                let overlapEnd = min(intervalEnd, end)
                guard overlapStart < overlapEnd else { continue }
                let sourceIndex = packet.source == .system ? 0 : 1
                for absoluteFrame in overlapStart ..< overlapEnd {
                    let sourceFrame = Int(absoluteFrame - start)
                    let destinationFrame = Int(absoluteFrame - intervalStart)
                    guard !occupied[destinationFrame * 2 + sourceIndex] else { continue }
                    occupied[destinationFrame * 2 + sourceIndex] = true
                    mix[destinationFrame * 2] += packet.samples[sourceFrame * 2]
                    mix[destinationFrame * 2 + 1] += packet.samples[sourceFrame * 2 + 1]
                }
            }
            let timestamp = (outputOrigin ?? origin) + Double(cursorFrame) / AudioFormat.sampleRate
            result.append(MixedAudioChunk(presentationTime: timestamp, frameCount: count, samples: mix))
            cursorFrame = intervalEnd
        }
        var retained: [NormalizedAudioPacket] = []
        retained.reserveCapacity(pending.count)
        pendingBytes = 0
        for packet in pending {
            let end = Int64(((packet.presentationTime - origin) * AudioFormat.sampleRate).rounded()) +
                Int64(packet.frameCount)
            if end > cursorFrame {
                retained.append(packet)
                pendingBytes += packet.samples.count * MemoryLayout<Float>.size
            }
        }
        pending = retained
        return result
    }
}
