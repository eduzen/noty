import Foundation
@testable import Noty
import XCTest

final class RecoveryNoticeStoreTests: XCTestCase {
    func testAcknowledgmentsPersistAcrossStoreInstancesAndStaySessionSpecific() throws {
        let suite = "NotyTests-Recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecoveryNoticeStore(defaults: defaults)
        first.acknowledge("/recordings/.noty-recovery-first")
        let second = RecoveryNoticeStore(defaults: defaults)
        XCTAssertTrue(second.isAcknowledged("/recordings/.noty-recovery-first"))
        XCTAssertFalse(second.isAcknowledged("/recordings/.noty-recovery-second"))
    }
}

final class MemoryRecoveryNoticeStore: RecoveryNoticeStoring {
    private var identifiers: Set<String> = []

    func isAcknowledged(_ identifier: String) -> Bool {
        identifiers.contains(identifier)
    }

    func acknowledge(_ identifier: String) {
        identifiers.insert(identifier)
    }
}
