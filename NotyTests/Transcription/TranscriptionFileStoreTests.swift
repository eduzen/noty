import Foundation
@testable import Noty
import XCTest

final class TranscriptionFileStoreTests: XCTestCase {
    private var temporaryURL: URL!
    private var store: TranscriptionFileStore!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        store = TranscriptionFileStore(rootURL: temporaryURL.appendingPathComponent("state"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryURL)
    }

    func testQueueRoundTripsAndCorruptQueueIsNotSilentlyDiscarded() throws {
        XCTAssertNil(try store.load([String].self))
        try store.save(["one", "two"])
        XCTAssertEqual(try store.load([String].self), ["one", "two"])
        try Data("broken".utf8).write(to: store.rootURL.appendingPathComponent("queue.json"))
        XCTAssertThrowsError(try store.load([String].self))
    }

    func testStagingCopiesAudioAndCleanupPreservesSourceAndCheckpoint() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let content = Data(repeating: 42, count: 128 * 1024)
        try content.write(to: source)
        let jobID = UUID()
        let staged = try store.stage(source: source, jobID: jobID)
        XCTAssertEqual(try Data(contentsOf: staged), content)
        let segments = [TranscriptSegment(start: 0, end: 1, text: "Hello", words: [])]
        try store.writeCheckpoint(segments: segments, jobID: jobID)
        try store.removeStaging(jobID: jobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: source), content)
        XCTAssertEqual(try store.readCheckpoint(jobID: jobID), segments)
    }

    func testConcurrentStagingSameJobReturnsOneCommittedCopyForEveryCaller() async throws {
        let store = try XCTUnwrap(store)
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let content = Data(repeating: 42, count: 2 * 1024 * 1024)
        try content.write(to: source)
        let jobID = UUID()
        let copies = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0 ..< 32 {
                group.addTask { try store.stage(source: source, jobID: jobID) }
            }
            var copies: [URL] = []
            for try await copy in group {
                copies.append(copy)
            }
            return copies
        }
        XCTAssertEqual(copies.count, 32)
        XCTAssertEqual(Set(copies), [store.stagedURL(jobID: jobID)])
        XCTAssertEqual(try Data(contentsOf: store.stagedURL(jobID: jobID)), content)
        XCTAssertEqual(try Data(contentsOf: source), content)
        let files = try FileManager.default.contentsOfDirectory(at: store.jobDirectory(id: jobID),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["input.m4a"])
    }

    func testStagingDoesNotAcceptDirectoryAtCommittedAudioPath() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: source)
        let jobID = UUID()
        try FileManager.default.createDirectory(at: store.stagedURL(jobID: jobID), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.stage(source: source, jobID: jobID))
        XCTAssertEqual(try Data(contentsOf: source), Data("audio".utf8))
    }

    func testExistingUserTranscriptIsPreservedAndGetsNumberedSuffix() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let existing = temporaryURL.appendingPathComponent("audio.txt")
        try Data("user notes".utf8).write(to: existing)
        let reservation = try store.reserveExport(sourceURL: source, text: "new transcript", previous: nil)
        XCTAssertEqual(reservation.url.lastPathComponent, "audio (2).txt")
        try store.publish(text: "new transcript", reservation: reservation)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "user notes")
        XCTAssertEqual(try String(contentsOf: reservation.url, encoding: .utf8), "new transcript")
    }

    func testPersistedReservationCanFinishAfterPublicationCrashWithoutDuplicate() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let reservation = try store.reserveExport(sourceURL: source, text: "same result", previous: nil)
        try store.save(reservation)
        try store.publish(text: "same result", reservation: reservation)
        let recovered = try XCTUnwrap(store.load(ExportReservation.self))
        try store.publish(text: "same result", reservation: recovered)
        let files = try FileManager.default.contentsOfDirectory(at: temporaryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "txt" }.count, 1)
    }

    func testRetryWithChangedTextUsesNewSidecarAndPreservesOriginal() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "plain", previous: nil)
        try Data("plain".utf8).write(to: previous.url)
        let next = try store.reserveExport(sourceURL: source, text: "Speaker 1: plain", previous: previous)
        XCTAssertEqual(next.url.lastPathComponent, "audio (2).txt")
        XCTAssertNotEqual(next.url, previous.url)
        try store.publish(text: "Speaker 1: plain", reservation: next)
        XCTAssertEqual(try String(contentsOf: next.url, encoding: .utf8), "Speaker 1: plain")
        XCTAssertEqual(try String(contentsOf: previous.url, encoding: .utf8), "plain")
    }

    func testIdenticalRetryReusesPublishedSidecarWithoutChangingIt() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "same result", previous: nil)
        try store.publish(text: "same result", reservation: previous)
        let attributes = try FileManager.default.attributesOfItem(atPath: previous.url.path)
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
        let next = try store.reserveExport(sourceURL: source, text: "same result", previous: previous)
        XCTAssertEqual(next.url, previous.url)
        try store.publish(text: "same result", reservation: next)
        let current = try FileManager.default.attributesOfItem(atPath: previous.url.path)
        XCTAssertEqual(try XCTUnwrap(current[.systemFileNumber] as? NSNumber).uint64Value, inode)
    }

    func testMissingPreviousSidecarCanReuseItsReservedPath() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "plain", previous: nil)
        let next = try store.reserveExport(sourceURL: source, text: "labeled", previous: previous)
        XCTAssertEqual(next.url, previous.url)
        try store.publish(text: "labeled", reservation: next)
        XCTAssertEqual(try String(contentsOf: next.url, encoding: .utf8), "labeled")
    }

    func testEditedOwnedTranscriptIsPreserved() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "plain", previous: nil)
        try store.publish(text: "plain", reservation: previous)
        try Data("user edits".utf8).write(to: previous.url)
        let next = try store.reserveExport(sourceURL: source, text: "labeled", previous: previous)
        XCTAssertNotEqual(next.url, previous.url)
        try store.publish(text: "labeled", reservation: next)
        XCTAssertEqual(try String(contentsOf: previous.url, encoding: .utf8), "user edits")
    }

    func testFileAppearingAfterReservationCannotBeOverwritten() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let reservation = try store.reserveExport(sourceURL: source, text: "transcript", previous: nil)
        try Data("new user file".utf8).write(to: reservation.url)
        XCTAssertThrowsError(try store.publish(text: "transcript", reservation: reservation))
        XCTAssertEqual(try String(contentsOf: reservation.url, encoding: .utf8), "new user file")
    }

    func testFileAppearingAtRetryReservationCannotBeOverwritten() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "plain", previous: nil)
        try store.publish(text: "plain", reservation: previous)
        let next = try store.reserveExport(sourceURL: source, text: "labeled", previous: previous)
        try Data("user edits".utf8).write(to: next.url)
        XCTAssertThrowsError(try store.publish(text: "labeled", reservation: next))
        XCTAssertEqual(try String(contentsOf: next.url, encoding: .utf8), "user edits")
        XCTAssertEqual(try String(contentsOf: previous.url, encoding: .utf8), "plain")
    }

    func testPriorOwnershipCannotAuthorizeReplacingDifferentContents() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let previous = try store.reserveExport(sourceURL: source, text: "plain", previous: nil)
        try store.publish(text: "plain", reservation: previous)
        var next = try store.reserveExport(sourceURL: source, text: "labeled", previous: previous)
        next.url = previous.url
        XCTAssertThrowsError(try store.publish(text: "labeled", reservation: next))
        XCTAssertEqual(try String(contentsOf: previous.url, encoding: .utf8), "plain")
    }

    func testConcurrentPublicationCannotReplaceWinningFile() async throws {
        let store = try XCTUnwrap(store)
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let firstReservation = try store.reserveExport(sourceURL: source, text: "first", previous: nil)
        let secondReservation = try store.reserveExport(sourceURL: source, text: "second", previous: nil)
        XCTAssertEqual(firstReservation.url, secondReservation.url)
        let first = Task.detached {
            Result { try store.publish(text: "first", reservation: firstReservation) }
        }
        let second = Task.detached {
            Result { try store.publish(text: "second", reservation: secondReservation) }
        }
        let results = [await first.value, await second.value]
        let successes = results.filter {
            if case .success = $0 {
                return true
            }
            return false
        }
        XCTAssertEqual(successes.count, 1)
        let output = try String(contentsOf: firstReservation.url, encoding: .utf8)
        XCTAssertTrue(output == "first" || output == "second")
    }

    func testMismatchedReservationDigestCannotPublish() throws {
        let source = temporaryURL.appendingPathComponent("audio.m4a")
        let reservation = try store.reserveExport(sourceURL: source, text: "expected", previous: nil)
        XCTAssertThrowsError(try store.publish(text: "different", reservation: reservation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.url.path))
    }
}
