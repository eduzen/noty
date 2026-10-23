import Foundation
import XCTest
@testable import Noty

final class MediaValidatorTests: XCTestCase {
    func testAcceptsReadablePlayable48KHzStereoMedia() async throws {
        let fileSystem = ValidatorFileSystem()
        let inspector = FakeMediaInspector(result: RecordingMediaInspection(isPlayable: true, sampleRate: 48_000, channelCount: 2, duration: 12.5))
        let url = URL(fileURLWithPath: "/recordings/good.m4a")
        fileSystem.existing.insert(url)
        let duration = try await MediaValidator(fileSystem: fileSystem, inspector: inspector).validate(url: url)
        XCTAssertEqual(duration, 12.5)
        XCTAssertEqual(inspector.inspectedURLs, [url])
    }

    func testMissingAndUnreadableFilesFailBeforeInspection() async {
        let fileSystem = ValidatorFileSystem()
        let inspector = FakeMediaInspector(result: validMedia)
        let validator = MediaValidator(fileSystem: fileSystem, inspector: inspector)
        do { _ = try await validator.validate(url: URL(fileURLWithPath: "/missing.m4a")); XCTFail("Expected missing file") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.missing") }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(inspector.inspectedURLs.isEmpty)
        let url = URL(fileURLWithPath: "/unreadable.m4a")
        fileSystem.existing.insert(url)
        fileSystem.unreadable.insert(url)
        do { _ = try await validator.validate(url: url); XCTFail("Expected unreadable file") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.missing") }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRejectsUnplayableMedia() async {
        let url = URL(fileURLWithPath: "/bad.m4a")
        let fileSystem = ValidatorFileSystem()
        fileSystem.existing.insert(url)
        let inspector = FakeMediaInspector(result: RecordingMediaInspection(isPlayable: false, sampleRate: 48_000, channelCount: 2, duration: 1))
        do { _ = try await MediaValidator(fileSystem: fileSystem, inspector: inspector).validate(url: url); XCTFail("Expected unplayable media") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.unplayable") }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRejectsWrongRateChannelCountAndZeroDuration() async {
        let cases = [
            RecordingMediaInspection(isPlayable: true, sampleRate: 44_100, channelCount: 2, duration: 1),
            RecordingMediaInspection(isPlayable: true, sampleRate: 48_000, channelCount: 1, duration: 1),
            RecordingMediaInspection(isPlayable: true, sampleRate: 48_000, channelCount: 2, duration: 0)
        ]
        for (index, media) in cases.enumerated() {
            let url = URL(fileURLWithPath: "/invalid-\(index).m4a")
            let fileSystem = ValidatorFileSystem()
            fileSystem.existing.insert(url)
            do {
                _ = try await MediaValidator(fileSystem: fileSystem, inspector: FakeMediaInspector(result: media)).validate(url: url)
                XCTFail("Expected invalid format")
            } catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.invalid-format") }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInspectionFailureMapsToUnreadableIssue() async {
        let url = URL(fileURLWithPath: "/corrupt.m4a")
        let fileSystem = ValidatorFileSystem()
        fileSystem.existing.insert(url)
        do { _ = try await MediaValidator(fileSystem: fileSystem, inspector: FakeMediaInspector(shouldFail: true)).validate(url: url); XCTFail("Expected inspection failure") }
        catch let issue as RecordingIssue { XCTAssertEqual(issue.code, "media.unreadable") }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private var validMedia: RecordingMediaInspection {
        RecordingMediaInspection(isPlayable: true, sampleRate: 48_000, channelCount: 2, duration: 2)
    }
}

private final class ValidatorFileSystem: RecordingMediaFileSystem {
    var existing: Set<URL> = []
    var unreadable: Set<URL> = []
    var directories: Set<URL> = []
    func createDirectory(at url: URL) throws { directories.insert(url) }
    func fileExists(at url: URL) -> Bool { existing.contains(url) }
    func isReadable(at url: URL) -> Bool { existing.contains(url) && !unreadable.contains(url) }
    func isDirectory(at url: URL) -> Bool { directories.contains(url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        (Array(existing) + Array(directories)).filter { $0.deletingLastPathComponent() == url }
    }
    func moveItem(at source: URL, to destination: URL) throws { existing.remove(source); existing.insert(destination) }
    func removeItem(at url: URL) throws {
        existing = existing.filter { $0 != url && !$0.path.hasPrefix(url.path + "/") }
        directories = directories.filter { $0 != url && !$0.path.hasPrefix(url.path + "/") }
    }
}

private final class FakeMediaInspector: RecordingMediaInspecting {
    let result: RecordingMediaInspection
    let shouldFail: Bool
    private(set) var inspectedURLs: [URL] = []
    init(result: RecordingMediaInspection = RecordingMediaInspection(isPlayable: true, sampleRate: 48_000, channelCount: 2, duration: 1), shouldFail: Bool = false) {
        self.result = result; self.shouldFail = shouldFail
    }
    func inspect(url: URL) async throws -> RecordingMediaInspection {
        inspectedURLs.append(url)
        if shouldFail { throw RecordingIssue(code: "inspection.failed", message: "failed") }
        return result
    }
}
