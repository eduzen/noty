import Foundation
@testable import Noty
import XCTest

@MainActor
final class AudioPlaybackControllerTests: XCTestCase {
    func testSwitchingTracksStopsPreviousAudioAndReleasesAccess() {
        let first = PlaybackTestPlayer()
        let second = PlaybackTestPlayer()
        var players = [first, second]
        let playback = AudioPlaybackController(makePlayer: { _ in players.removeFirst() })
        var released = false
        playback.toggle(id: UUID()) { self.source { released = true } }
        let secondID = UUID()
        playback.toggle(id: secondID) { self.source() }
        XCTAssertFalse(first.isPlaying)
        XCTAssertTrue(released)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.activeID, secondID)
        playback.stop()
    }

    func testPauseAndResumeKeepPositionAndSeekIsBounded() {
        let player = PlaybackTestPlayer()
        let playback = AudioPlaybackController(makePlayer: { _ in player })
        let id = UUID()
        playback.toggle(id: id) { self.source() }
        playback.seek(to: 4)
        playback.toggle(id: id) {
            XCTFail("Must reuse the open file")
            return self.source()
        }
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 4)
        playback.toggle(id: id) {
            XCTFail("Must reuse the open file")
            return self.source()
        }
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(player.currentTime, 4)
        playback.seek(to: -5)
        XCTAssertEqual(playback.currentTime, 0)
        playback.seek(to: 50)
        XCTAssertEqual(playback.currentTime, 10)
        playback.seek(to: .nan)
        XCTAssertTrue(playback.currentTime.isFinite)
        playback.stop()
    }

    func testCompletionResetsPlaybackAndReleasesAccess() {
        let player = PlaybackTestPlayer()
        let playback = AudioPlaybackController(makePlayer: { _ in player })
        var released = false
        playback.toggle(id: UUID()) { self.source { released = true } }
        player.currentTime = 10
        player.isPlaying = false
        playback.refresh()
        XCTAssertNil(playback.activeID)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertTrue(released)
    }

    func testFailureReleasesAccessAndShowsError() {
        let playback = AudioPlaybackController(makePlayer: { _ in throw CocoaError(.fileReadNoSuchFile) })
        var released = false
        playback.toggle(id: UUID()) { self.source { released = true } }
        XCTAssertTrue(released)
        XCTAssertNil(playback.activeID)
        XCTAssertNotNil(playback.issue)
        XCTAssertFalse(playback.isPlaying)
    }

    func testPlayerRefusingToPlayReleasesAccess() {
        let player = PlaybackTestPlayer()
        player.canPlay = false
        let playback = AudioPlaybackController(makePlayer: { _ in player })
        var released = false
        playback.toggle(id: UUID()) { self.source { released = true } }
        XCTAssertTrue(released)
        XCTAssertNil(playback.activeID)
        XCTAssertNotNil(playback.issue)
    }

    private func source(release: (() -> Void)? = nil) -> (url: URL, lease: DestinationLease) {
        let url = URL(fileURLWithPath: "/tmp/recording.m4a")
        return (url, DestinationLease(url: url.deletingLastPathComponent(), releaseAccess: release))
    }
}

@MainActor
final class PlaybackTestPlayer: AudioPlaybackPlaying {
    var duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var canPlay = true

    func play() -> Bool {
        isPlaying = canPlay
        return canPlay
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
    }
}
