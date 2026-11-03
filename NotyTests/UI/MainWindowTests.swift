import AppKit
@testable import Noty
import XCTest

@MainActor
final class MainWindowTests: XCTestCase {
    func testAppRemainsAccessibleFromDockWithoutMenuBarIcon() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, false)
    }

    func testClosingLastWindowDoesNotTerminateApp() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
