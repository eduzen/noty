import Foundation
@testable import Noty
import XCTest

final class GoogleOAuthLoopbackTests: XCTestCase {
    func testRedirectWithCodeReachesTheWaiter() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.cancel() }
        let port = try await listener.start()
        let waiting = Task { try await listener.awaitRedirect() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz"))
        let (_, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let redirect = try await waiting.value
        let code = try GoogleOAuthRedirect.authorizationCode(from: redirect, expectedState: "xyz")
        XCTAssertEqual(code, "abc")
    }

    func testUnrelatedRequestsAreIgnoredUntilTheRedirectArrives() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.cancel() }
        let port = try await listener.start()
        let waiting = Task { try await listener.awaitRedirect() }

        let faviconURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/favicon.ico"))
        let (_, notFound) = try await URLSession.shared.data(from: faviconURL)
        XCTAssertEqual((notFound as? HTTPURLResponse)?.statusCode, 404)

        let redirectURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz"))
        _ = try await URLSession.shared.data(from: redirectURL)
        let redirect = try await waiting.value
        let code = try GoogleOAuthRedirect.authorizationCode(from: redirect, expectedState: "xyz")
        XCTAssertEqual(code, "abc")
    }

    func testCancelFailsAPendingWait() async throws {
        let listener = LoopbackRedirectListener()
        _ = try await listener.start()
        let waiting = Task { try await listener.awaitRedirect() }
        listener.cancel()

        do {
            _ = try await waiting.value
            XCTFail("Expected the wait to fail after cancel")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRedirectParserRejectsWrongStateAndUserDenial() throws {
        let wrongState = try XCTUnwrap(URL(string: "http://127.0.0.1/?code=abc&state=other"))
        XCTAssertThrowsError(try GoogleOAuthRedirect.authorizationCode(from: wrongState, expectedState: "xyz"))

        let denied = try XCTUnwrap(URL(string: "http://127.0.0.1/?error=access_denied&state=xyz"))
        XCTAssertThrowsError(
            try GoogleOAuthRedirect.authorizationCode(from: denied, expectedState: "xyz")
        ) { error in
            XCTAssertEqual(error as? GoogleCalendarError, .authorizationCancelled)
        }
    }
}
