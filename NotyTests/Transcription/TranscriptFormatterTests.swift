import Foundation
@testable import Noty
import XCTest

final class TranscriptFormatterTests: XCTestCase {
    func testLabelsFollowFirstAppearanceAndWordsUseGreatestOverlap() {
        let segments = [segment(0, "Hello there. Goodbye.", [
            word(0, 1, "Hello"), word(1, 2, " there."), word(2, 3, " Goodbye.")
        ])]
        let speakers = [SpeakerInterval(start: 0, end: 1.1, speaker: 9),
                        SpeakerInterval(start: 1.1, end: 3, speaker: 2)]

        XCTAssertEqual(TranscriptFormatter.format(segments: segments, speakers: speakers),
                       "[00:00:00] Speaker 1: Hello\n[00:00:01] Speaker 2: there. Goodbye.\n")
    }

    func testUnmatchedAndMissingWordTimingsPreserveTextAsUnknown() {
        let segments = [segment(0, "Unmatched words", [word(0, 1, "Unmatched"), word(1, 2, " words")]),
                        segment(3, "No timing for this sentence.", [])]
        XCTAssertEqual(TranscriptFormatter.format(segments: segments, speakers: []),
                       "[00:00:00] Unknown: Unmatched words No timing for this sentence.\n")
    }

    func testPartialWordResultsDoNotDiscardSegmentText() {
        let segments = [segment(0, "The complete sentence.", [word(0, 1, "The")])]
        let output = TranscriptFormatter.format(segments: segments,
                                                speakers: [SpeakerInterval(start: 0, end: 5, speaker: 0)])
        XCTAssertEqual(output, "[00:00:00] Unknown: The complete sentence.\n")
    }

    func testSortsSegmentsChronologicallyAndMergesSameSpeakerAcrossSegments() {
        let segments = [segment(3662, "Later.", [word(3662, 3663, "Later.")]),
                        segment(1, "First.", [word(1, 2, "First.")])]
        let output = TranscriptFormatter.format(segments: segments,
                                                speakers: [SpeakerInterval(start: 0, end: 4000, speaker: 4)])
        XCTAssertEqual(output, "[00:00:01] Speaker 1: First. Later.\n")
    }

    func testInvalidTimingsCannotCrashFormattingOrInventSpeaker() {
        let output = TranscriptFormatter.format(
            segments: [segment(.nan, "Still readable.", [word(.nan, .infinity, "Still readable.")])],
            speakers: [SpeakerInterval(start: 0, end: .infinity, speaker: 0)]
        )
        XCTAssertEqual(output, "[00:00:00] Unknown: Still readable.\n")
    }

    func testSilenceAndFallbackWarningAreReadable() {
        XCTAssertEqual(TranscriptFormatter.format(segments: [], speakers: []), "No speech detected.\n")
        XCTAssertEqual(TranscriptFormatter.format(segments: [], speakers: [], speakerWarning: "Labels unavailable."),
                       "Labels unavailable.\n\nNo speech detected.\n")
    }

    func testTwoHourWordTimelineKeepsEverySpeakerTurn() {
        let words: [TranscriptWord] = (0 ..< 20000).map { index in
            let start = Double(index) * 0.36
            let end = Double(index + 1) * 0.36
            let text = index == 0 ? "word" : " word"
            return word(start, end, text)
        }
        let intervals: [SpeakerInterval] = (0 ..< 10000).map { index in
            SpeakerInterval(start: Double(index) * 0.72, end: Double(index + 1) * 0.72, speaker: index % 2)
        }
        let output = TranscriptFormatter.format(segments: [segment(0, words.map(\.text).joined(), words)],
                                                speakers: intervals)
        XCTAssertEqual(output.components(separatedBy: "word").count - 1, 20000)
        XCTAssertEqual(output.split(separator: "\n").count, 10000)
        XCTAssertTrue(output.hasPrefix("[00:00:00] Speaker 1: word word\n"))
        XCTAssertTrue(output.contains("Speaker 2: word word"))
    }

    private func word(_ start: Double, _ end: Double, _ text: String) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text)
    }

    private func segment(_ start: Double, _ text: String, _ words: [TranscriptWord]) -> TranscriptSegment {
        TranscriptSegment(start: start, end: words.last?.end ?? start + 2, text: text, words: words)
    }
}
