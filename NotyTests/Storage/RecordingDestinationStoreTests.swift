import Foundation
@testable import Noty
import XCTest

final class RecordingDestinationStoreTests: XCTestCase {
    func testFirstUseCreatesAndLeasesDefaultMusicFolder() throws {
        let fs = FakeDestinationFileSystem()
        let store = makeStore(fileSystem: fs)

        let lease = try store.resolveCurrentDestination()
        XCTAssertEqual(lease.url, URL(fileURLWithPath: "/virtual/Music/Noty", isDirectory: true))
        XCTAssertEqual(fs.created, [lease.url])
        XCTAssertEqual(fs.activeScopes, 1)
        lease.close()
        XCTAssertEqual(fs.activeScopes, 0)
    }

    func testInaccessibleDestinationFailsWithActionableIssue() {
        let fs = FakeDestinationFileSystem()
        fs.unwritable.insert(URL(fileURLWithPath: "/saved", isDirectory: true))
        let bookmarks = FakeBookmarkProvider()
        bookmarks.register(Data("saved".utf8), url: URL(fileURLWithPath: "/saved", isDirectory: true))
        let store = makeStore(
            fileSystem: fs,
            bookmarks: bookmarks,
            bookmarkStore: FakeBookmarkStore(data: Data("saved".utf8))
        )

        XCTAssertThrowsError(try store.resolveCurrentDestination()) { error in
            guard let issue = error as? RecordingIssue else { return XCTFail("Expected RecordingIssue") }
            XCTAssertEqual(issue.code, "destination-not-writable")
            XCTAssertTrue(issue.message.contains("choose another"))
        }
        XCTAssertEqual(fs.activeScopes, 0)
    }

    func testStaleBookmarkIsRefreshedAndLeaseHoldsScope() throws {
        let fs = FakeDestinationFileSystem()
        let provider = FakeBookmarkProvider()
        provider.register(Data("old".utf8), url: URL(fileURLWithPath: "/moved", isDirectory: true), stale: true)
        let store = makeStore(
            fileSystem: fs,
            bookmarks: provider,
            bookmarkStore: FakeBookmarkStore(data: Data("old".utf8))
        )

        let lease = try store.resolveCurrentDestination()
        XCTAssertEqual(lease.url.path, "/moved")
        XCTAssertEqual(provider.createdURLs, [lease.url])
        XCTAssertEqual(fs.activeScopes, 1)
        lease.close()
        lease.close()
        XCTAssertEqual(fs.activeScopes, 0)
    }

    func testMovedFolderIsResolvedToItsCurrentURL() throws {
        let fs = FakeDestinationFileSystem()
        let provider = FakeBookmarkProvider()
        provider.register(Data("moved-bookmark".utf8), url: URL(fileURLWithPath: "/new-location", isDirectory: true))
        let store = makeStore(
            fileSystem: fs,
            bookmarks: provider,
            bookmarkStore: FakeBookmarkStore(data: Data("moved-bookmark".utf8))
        )

        let lease = try store.resolveCurrentDestination()
        XCTAssertEqual(lease.url.path, "/new-location")
        lease.close()
    }

    func testSelectedFolderRequiresSecurityScopedAccess() {
        let selected = URL(fileURLWithPath: "/chosen", isDirectory: true)
        let saved = Data("previous".utf8)
        let dataStore = FakeBookmarkStore(data: saved)
        let fs = FakeDestinationFileSystem()
        fs.acquireScope = false
        let store = makeStore(fileSystem: fs, panel: FakeDestinationPanel(url: selected), bookmarkStore: dataStore)

        XCTAssertThrowsError(try store.chooseFolder()) { error in
            XCTAssertEqual((error as? RecordingIssue)?.code, "destination-security-scope-unavailable")
        }
        XCTAssertEqual(dataStore.bookmarkData, saved)
    }

    func testInvalidNewFolderDoesNotReplaceSavedBookmark() {
        let saved = Data("previous".utf8)
        let storeData = FakeBookmarkStore(data: saved)
        let fs = FakeDestinationFileSystem()
        fs.unwritable.insert(URL(fileURLWithPath: "/bad-choice", isDirectory: true))
        let store = makeStore(
            fileSystem: fs,
            panel: FakeDestinationPanel(url: URL(fileURLWithPath: "/bad-choice", isDirectory: true)),
            bookmarkStore: storeData
        )

        XCTAssertThrowsError(try store.chooseFolder())
        XCTAssertEqual(storeData.bookmarkData, saved)
    }

    func testChoosingFolderPersistsOnlyAfterValidationAndReturnsLease() throws {
        let selected = URL(fileURLWithPath: "/chosen", isDirectory: true)
        let dataStore = FakeBookmarkStore()
        let fs = FakeDestinationFileSystem()
        let provider = FakeBookmarkProvider()
        let store = makeStore(
            fileSystem: fs,
            bookmarks: provider,
            panel: FakeDestinationPanel(url: selected),
            bookmarkStore: dataStore
        )

        let lease = try store.chooseFolder()
        XCTAssertEqual(lease.url, selected)
        XCTAssertEqual(dataStore.bookmarkData, provider.createdData.last)
        XCTAssertEqual(fs.activeScopes, 1)
        lease.close()
        XCTAssertEqual(fs.activeScopes, 0)
    }

    private func makeStore(
        fileSystem: FakeDestinationFileSystem,
        bookmarks: FakeBookmarkProvider = FakeBookmarkProvider(),
        panel: FakeDestinationPanel = FakeDestinationPanel(url: URL(fileURLWithPath: "/chosen", isDirectory: true)),
        bookmarkStore: FakeBookmarkStore = FakeBookmarkStore()
    ) -> RecordingDestinationStore {
        RecordingDestinationStore(
            bookmarks: bookmarks,
            fileSystem: fileSystem,
            panel: panel,
            bookmarkStore: bookmarkStore,
            defaultDirectory: URL(fileURLWithPath: "/virtual/Music/Noty", isDirectory: true)
        )
    }
}

private final class FakeDestinationFileSystem: RecordingDestinationFileSystem {
    private(set) var created: [URL] = []
    private(set) var activeScopes = 0
    var unwritable: Set<URL> = []
    var acquireScope = true

    func createDirectoryIfNeeded(at url: URL) throws {
        created.append(url)
    }

    func startAccessing(_: URL) -> Bool {
        guard acquireScope else { return false }
        activeScopes += 1
        return true
    }

    func stopAccessing(_: URL) {
        activeScopes -= 1
    }

    func isDirectory(_: URL) -> Bool {
        true
    }

    func verifyWritable(_ url: URL) throws {
        if unwritable.contains(url) {
            throw RecordingIssue(
                code: "destination-not-writable",
                message: "Noty cannot write to this folder. Check its permissions or choose another location."
            )
        }
    }
}

private final class FakeBookmarkProvider: RecordingBookmarkProviding {
    private var values: [Data: (URL, Bool)] = [:]
    private(set) var createdURLs: [URL] = []
    private(set) var createdData: [Data] = []

    func register(_ data: Data, url: URL, stale: Bool = false) {
        values[data] = (url, stale)
    }

    func makeBookmark(for url: URL) throws -> Data {
        let data = Data("bookmark-\(createdData.count)".utf8)
        values[data] = (url, false)
        createdURLs.append(url)
        createdData.append(data)
        return data
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let (url, stale) = values[data] else { throw RecordingIssue(code: "missing", message: "missing") }
        return (url, stale)
    }
}

private final class FakeDestinationPanel: RecordingDestinationPanel {
    let url: URL
    init(url: URL) {
        self.url = url
    }

    func chooseDirectory() throws -> URL {
        url
    }
}

private final class FakeBookmarkStore: RecordingDestinationBookmarkStore {
    var bookmarkData: Data?
    init(data: Data? = nil) {
        bookmarkData = data
    }

    func save(bookmarkData: Data) {
        self.bookmarkData = bookmarkData
    }
}
