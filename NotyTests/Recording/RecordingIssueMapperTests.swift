import Foundation
@testable import Noty
import XCTest

final class RecordingIssueMapperTests: XCTestCase {
    func testTechnicalErrorsDoNotExposeFrameworkDetailsOrPaths() {
        let errors: [Error] = [
            CaptureServiceError.streamFailure("read UID failed (OSStatus -50)"),
            AudioPipelineError.conversionFailed("Audio converter did not consume all callback input."),
            AudioPipelineError.queueOverflow,
            NSError(domain: "NSCocoaErrorDomain", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "/Users/person/private/audio.tmp could not be opened"])
        ]
        for error in errors {
            let issue = RecordingIssueMapper.issue(from: error)
            XCTAssertFalse(issue.message.contains("OSStatus"))
            XCTAssertFalse(issue.message.contains("UID"))
            XCTAssertFalse(issue.message.contains("callback"))
            XCTAssertFalse(issue.message.contains("bounded buffer"))
            XCTAssertFalse(issue.message.contains("/Users/"))
            XCTAssertFalse(issue.message.isEmpty)
        }
    }
}
