import AppKit
import Foundation

protocol RecordingBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

protocol RecordingDestinationFileSystem {
    func createDirectoryIfNeeded(at url: URL) throws
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func isDirectory(_ url: URL) -> Bool
    func verifyWritable(_ url: URL) throws
}

protocol RecordingDestinationPanel {
    func chooseDirectory() throws -> URL
}

protocol RecordingDestinationBookmarkStore {
    var bookmarkData: Data? { get }
    func save(bookmarkData: Data)
}

struct SecurityScopedBookmarkProvider: RecordingBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }
}

struct LocalRecordingDestinationFileSystem: RecordingDestinationFileSystem {
    func createDirectoryIfNeeded(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func verifyWritable(_ url: URL) throws {
        guard isDirectory(url) else { throw RecordingDestinationStore.issue(
            "destination-not-folder",
            "The selected recording destination is not a folder. Choose another folder."
        ) }
        let probe = url.appendingPathComponent(".noty-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw RecordingDestinationStore.issue(
                "destination-not-writable",
                "Noty cannot write to this folder. Check its permissions or choose another location."
            )
        }
    }
}

struct OpenRecordingDestinationPanel: RecordingDestinationPanel {
    func chooseDirectory() throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Recording Folder"
        guard panel.runModal() == .OK, let url = panel.url else {
            throw RecordingDestinationStore.issue(
                "destination-selection-cancelled",
                "No recording folder was selected."
            )
        }
        return url
    }
}

final class UserDefaultsRecordingDestinationBookmarkStore: RecordingDestinationBookmarkStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "recordingDestinationBookmark") {
        self.defaults = defaults
        self.key = key
    }

    var bookmarkData: Data? {
        defaults.data(forKey: key)
    }

    func save(bookmarkData: Data) {
        defaults.set(bookmarkData, forKey: key)
    }
}

/// A destination's folder URL and the security-scope access held for its lifetime.
final class DestinationLease {
    let url: URL
    private let releaseAccess: (() -> Void)?
    private var isClosed = false

    init(url: URL, releaseAccess: (() -> Void)?) {
        self.url = url
        self.releaseAccess = releaseAccess
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        releaseAccess?()
    }

    deinit { close() }
}

struct RecordingDestinationStore {
    private let bookmarks: RecordingBookmarkProviding
    private let fileSystem: RecordingDestinationFileSystem
    private let panel: RecordingDestinationPanel
    private let bookmarkStore: RecordingDestinationBookmarkStore
    private let defaultDirectory: URL

    init(
        bookmarks: RecordingBookmarkProviding = SecurityScopedBookmarkProvider(),
        fileSystem: RecordingDestinationFileSystem = LocalRecordingDestinationFileSystem(),
        panel: RecordingDestinationPanel = OpenRecordingDestinationPanel(),
        bookmarkStore: RecordingDestinationBookmarkStore = UserDefaultsRecordingDestinationBookmarkStore(),
        defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Music/Noty",
            isDirectory: true
        )
    ) {
        self.bookmarks = bookmarks
        self.fileSystem = fileSystem
        self.panel = panel
        self.bookmarkStore = bookmarkStore
        self.defaultDirectory = defaultDirectory
    }

    func resolveCurrentDestination() throws -> DestinationLease {
        if let data = bookmarkStore.bookmarkData {
            let resolved: (url: URL, isStale: Bool)
            do {
                resolved = try bookmarks.resolveBookmark(data)
            } catch {
                throw Self.issue(
                    "destination-bookmark-unavailable",
                    "Noty's saved recording folder is unavailable. Choose the folder again in Recording Settings."
                )
            }
            let lease = try openAndValidate(resolved.url, requiresSecurityScope: true)
            if resolved.isStale {
                do { try bookmarkStore.save(bookmarkData: bookmarks.makeBookmark(for: resolved.url)) } catch {
                    lease.close()
                    throw Self.issue(
                        "destination-bookmark-refresh-failed",
                        "Noty opened the recording folder but could not refresh its access bookmark. " +
                            "Choose the folder again."
                    )
                }
            }
            return lease
        }

        do { try fileSystem.createDirectoryIfNeeded(at: defaultDirectory) } catch { throw Self.issue(
            "destination-default-unavailable",
            "Noty could not create ~/Music/Noty. Choose another recording folder."
        ) }
        return try openAndValidate(defaultDirectory, requiresSecurityScope: false)
    }

    func chooseFolder() throws -> DestinationLease {
        let selected: URL
        do { selected = try panel.chooseDirectory() } catch let issue as RecordingIssue { throw issue } catch {
            throw Self.issue(
                "destination-selection-failed",
                "Noty could not open the folder chooser. Try again."
            )
        }

        let lease = try openAndValidate(selected, requiresSecurityScope: true)
        do { try bookmarkStore.save(bookmarkData: bookmarks.makeBookmark(for: selected)) } catch {
            lease.close()
            throw Self.issue(
                "destination-bookmark-save-failed",
                "Noty could not save access to this folder. Choose a different folder or check its permissions."
            )
        }
        return lease
    }

    private func openAndValidate(_ url: URL, requiresSecurityScope: Bool) throws -> DestinationLease {
        let acquiredScope = fileSystem.startAccessing(url)
        guard acquiredScope || !requiresSecurityScope else {
            throw Self.issue(
                "destination-security-scope-unavailable",
                "Noty could not obtain access to this folder. Choose it again and approve access when prompted."
            )
        }
        do {
            try fileSystem.verifyWritable(url)
            return DestinationLease(
                url: url,
                releaseAccess: acquiredScope ? { [fileSystem] in fileSystem.stopAccessing(url) } : nil
            )
        } catch let issue as RecordingIssue {
            if acquiredScope {
                fileSystem.stopAccessing(url)
            }
            throw issue
        } catch {
            if acquiredScope {
                fileSystem.stopAccessing(url)
            }
            throw Self.issue(
                "destination-inaccessible",
                "Noty cannot access this recording folder. Restore access or choose another folder."
            )
        }
    }

    fileprivate static func issue(_ code: String, _ message: String) -> RecordingIssue {
        RecordingIssue(code: code, message: message, isRetryAllowed: true)
    }
}
