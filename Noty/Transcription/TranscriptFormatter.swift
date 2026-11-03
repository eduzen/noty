import Foundation

enum TranscriptFormatter {
    private struct IntervalIndex {
        var intervals: [SpeakerInterval]
        var maximumEnds: [Double]

        init(_ speakers: [SpeakerInterval]) {
            intervals = speakers.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
                .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
            var maximum = -Double.infinity
            maximumEnds = intervals.map {
                maximum = max(maximum, $0.end)
                return maximum
            }
        }

        func firstOverlap(after start: Double) -> Int {
            var lower = 0
            var upper = maximumEnds.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if maximumEnds[middle] <= start {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }
    }

    private struct Piece {
        var start: Double
        var text: String
        var speaker: Int?
        var segment: Int
    }

    private struct Turn {
        var start: Double
        var text: String
        var speaker: Int?
        var lastSegment: Int
    }

    static func format(segments: [TranscriptSegment], speakers: [SpeakerInterval],
                       speakerWarning: String? = nil) -> String {
        let intervals = IntervalIndex(speakers)
        let pieces = segments.enumerated().flatMap { index, segment -> [Piece] in
            let wordText = segment.words.map(\.text).joined()
            let text = segment.text.isEmpty ? wordText : segment.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            // Word timestamps can be absent or incomplete. Preserve the complete segment in either case.
            guard !segment.words.isEmpty,
                  wordText.trimmingCharacters(in: .whitespacesAndNewlines) ==
                  text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return [Piece(start: safeTime(segment.start), text: text, speaker: nil, segment: index)]
            }
            return segment.words.map {
                Piece(start: safeTime($0.start), text: $0.text,
                      speaker: speaker(for: $0, intervals: intervals), segment: index)
            }
        }.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)

        var turns: [Turn] = []
        var labels: [Int: Int] = [:]
        for piece in pieces {
            if let speaker = piece.speaker, labels[speaker] == nil {
                labels[speaker] = labels.count + 1
            }
            if let last = turns.indices.last, turns[last].speaker == piece.speaker {
                let needsSpace = turns[last].lastSegment != piece.segment &&
                    turns[last].text.last?.isWhitespace == false && piece.text.first?.isWhitespace == false
                turns[last].text += (needsSpace ? " " : "") + piece.text
                turns[last].lastSegment = piece.segment
            } else {
                turns.append(Turn(start: piece.start, text: piece.text,
                                  speaker: piece.speaker, lastSegment: piece.segment))
            }
        }

        let lines = turns.map { turn in
            let label = turn.speaker.flatMap { labels[$0] }.map { "Speaker \($0)" } ?? "Unknown"
            return "[\(timestamp(turn.start))] \(label): \(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let transcript = lines.isEmpty ? "No speech detected.\n" : lines.joined(separator: "\n") + "\n"
        guard let warning = speakerWarning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty else {
            return transcript
        }
        return warning + "\n\n" + transcript
    }

    private static func speaker(for word: TranscriptWord, intervals: IntervalIndex) -> Int? {
        guard word.start.isFinite, word.end.isFinite, word.end > word.start else { return nil }
        var overlaps: [Int: Double] = [:]
        for index in intervals.firstOverlap(after: word.start) ..< intervals.intervals.count {
            let interval = intervals.intervals[index]
            if interval.start >= word.end {
                break
            }
            let overlap = min(word.end, interval.end) - max(word.start, interval.start)
            if overlap > 0 {
                overlaps[interval.speaker, default: 0] += overlap
            }
        }
        return overlaps.keys.sorted().max {
            let left = overlaps[$0, default: 0]
            let right = overlaps[$1, default: 0]
            return left == right ? $0 > $1 : left < right
        }
    }

    private static func safeTime(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func timestamp(_ value: Double) -> String {
        let seconds = Int(min(safeTime(value), Double(Int.max / 2)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }
}
