import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TranscriptionController {
    func importAudio() async {
        guard canImport else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Audio for Transcription"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        let sources = panel.urls.filter { $0.pathExtension.lowercased() == "m4a" }
        guard !sources.isEmpty else {
            reportImportError("Choose an .m4a audio file to transcribe.")
            return
        }
        let folders = sources.reduce(into: [URL]()) { result, source in
            let folder = source.deletingLastPathComponent().standardizedFileURL
            if !result.contains(folder) {
                result.append(folder)
            }
        }
        for folder in folders {
            guard canImport else { return }
            let folderPanel = NSOpenPanel()
            folderPanel.title = "Allow Transcript Saving"
            folderPanel.message = "Select \(folder.lastPathComponent) to allow Noty to save transcripts "
                + "beside the audio."
            folderPanel.prompt = "Allow Saving Here"
            folderPanel.directoryURL = folder
            folderPanel.canChooseDirectories = true
            folderPanel.canChooseFiles = false
            folderPanel.canCreateDirectories = false
            guard folderPanel.runModal() == .OK, let selectedFolder = folderPanel.url else { continue }
            guard selectedFolder.resolvingSymlinksInPath().standardizedFileURL ==
                folder.resolvingSymlinksInPath().standardizedFileURL
            else {
                reportImportError("Choose the folder containing the audio so its transcript can be saved beside it.")
                continue
            }
            await importAudio(in: selectedFolder, sources: sources.filter {
                $0.deletingLastPathComponent().standardizedFileURL == folder
            })
        }
    }

    private func importAudio(in folder: URL, sources: [URL]) async {
        guard folder.startAccessingSecurityScopedResource() else {
            reportImportError("Noty could not access this folder. Import the audio again and allow folder access.")
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let bookmark: Data
        do {
            bookmark = try folder.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            reportImportError("Noty could not keep access to this folder. Import the audio again.")
            return
        }
        for source in sources {
            guard canImport else { return }
            do {
                let duration = try await TranscriptionAudioImport.duration(at: source)
                await enqueue(sourceURL: source, duration: duration, folderBookmark: bookmark)
            } catch {
                reportImportError("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

enum TranscriptionAudioImport {
    static func duration(at url: URL) async throws -> TimeInterval {
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a",
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ImportError.unreadableAudio
        }
        do {
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try CMTimeGetSeconds(await asset.load(.duration))
            guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
                throw ImportError.unreadableAudio
            }
            return duration
        } catch {
            throw ImportError.unreadableAudio
        }
    }

    private enum ImportError: LocalizedError {
        case unreadableAudio

        var errorDescription: String? {
            "This file is not a playable .m4a recording. Choose another audio file."
        }
    }
}
