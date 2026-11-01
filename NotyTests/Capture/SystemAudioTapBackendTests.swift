import CoreAudio
@testable import Noty
import XCTest

final class SystemAudioTapBackendTests: XCTestCase {
    func testTapCreationFailurePreservesCoreAudioDiagnostic() {
        XCTAssertThrowsError(try SystemAudioTapBackend.createProcessTap(CATapDescription(), using: { _, _ in
            kAudioHardwareIllegalOperationError
        })) { error in
            XCTAssertEqual(
                error as? CaptureServiceError,
                .streamFailure("System audio capture could not create process tap (OSStatus 1852797029).")
            )
        }
    }
}
