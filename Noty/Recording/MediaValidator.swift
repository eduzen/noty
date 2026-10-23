import AVFoundation
import Foundation

struct RecordingMediaInspection: Equatable, Sendable {
    let isPlayable: Bool
    let sampleRate: Double?
    let channelCount: Int?
    let duration: TimeInterval
}

protocol RecordingMediaInspecting {
    func inspect(url: URL) async throws -> RecordingMediaInspection
}

protocol RecordingMediaValidating {
    func validate(url: URL) async throws -> TimeInterval
}

struct MediaValidator: RecordingMediaValidating {
    let fileSystem: RecordingMediaFileSystem
    let inspector: RecordingMediaInspecting

    init(fileSystem: RecordingMediaFileSystem = LocalRecordingMediaFileSystem(),
         inspector: RecordingMediaInspecting = AVRecordingMediaInspector()) {
        self.fileSystem = fileSystem
        self.inspector = inspector
    }

    func validate(url: URL) async throws -> TimeInterval {
        guard fileSystem.fileExists(at: url), fileSystem.isReadable(at: url) else {
            throw RecordingIssue(code: "media.missing", message: "The recording file is missing or unreadable.", recoveryURL: url, isRetryAllowed: false)
        }
        let media: RecordingMediaInspection
        do { media = try await inspector.inspect(url: url) }
        catch {
            throw RecordingIssue(code: "media.unreadable", message: "The recording could not be read.", recoveryURL: url, isRetryAllowed: false)
        }
        guard media.isPlayable else {
            throw RecordingIssue(code: "media.unplayable", message: "The recording could not be played.", recoveryURL: url, isRetryAllowed: false)
        }
        guard media.sampleRate == AudioFormat.sampleRate,
              media.channelCount == AudioFormat.channelCount,
              media.duration.isFinite, media.duration > 0 else {
            throw RecordingIssue(code: "media.invalid-format", message: "The recording has an invalid audio format or duration.", recoveryURL: url, isRetryAllowed: false)
        }
        return media.duration
    }
}

struct AVRecordingMediaInspector: RecordingMediaInspecting {
    func inspect(url: URL) async throws -> RecordingMediaInspection {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
            return RecordingMediaInspection(isPlayable: false, sampleRate: nil, channelCount: nil, duration: 0)
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let asbd = descriptions.compactMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }).first else {
            return RecordingMediaInspection(isPlayable: false, sampleRate: nil, channelCount: nil, duration: 0)
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return RecordingMediaInspection(isPlayable: playable, sampleRate: asbd.mSampleRate,
                                        channelCount: Int(asbd.mChannelsPerFrame), duration: duration)
    }
}

protocol RecordingMediaFileSystem {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

struct LocalRecordingMediaFileSystem: RecordingMediaFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func isReadable(at url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
    }
    func moveItem(at source: URL, to destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
}
