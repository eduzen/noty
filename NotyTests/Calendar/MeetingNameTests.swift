import Foundation
@testable import Noty
import XCTest

final class MeetingEventSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testInProgressTimedEventNamesRecording() {
        let events = [event(title: "Design review", start: 900, end: 2000)]
        XCTAssertEqual(MeetingEventSelection.title(in: events, at: now), "Design review")
    }

    func testEventsThatEndedOrStartLaterAreIgnored() {
        let events = [
            event(title: "Ended", start: 0, end: 1000),
            event(title: "Later", start: 1001, end: 2000)
        ]
        XCTAssertNil(MeetingEventSelection.title(in: events, at: now))
    }

    func testOverlappingEventsUseTheLatestStart() {
        let events = [
            event(title: "Standup", start: 900, end: 2000),
            event(title: "Design review", start: 950, end: 1500)
        ]
        XCTAssertEqual(MeetingEventSelection.title(in: events, at: now), "Design review")
    }

    func testAllDayCancelledAndUntitledEventsAreSkipped() {
        let events = [
            event(title: "Offsite", start: nil, end: nil, allDay: true),
            event(title: "Cancelled sync", start: 900, end: 2000, cancelled: true),
            event(title: "   ", start: 900, end: 2000),
            event(title: nil, start: 900, end: 2000)
        ]
        XCTAssertNil(MeetingEventSelection.title(in: events, at: now))
    }

    func testTitleIsTrimmed() {
        let events = [event(title: "  Planning  ", start: 900, end: 2000)]
        XCTAssertEqual(MeetingEventSelection.title(in: events, at: now), "Planning")
    }

    private func event(title: String?, start: TimeInterval?, end: TimeInterval?,
                       allDay: Bool = false, cancelled: Bool = false) -> CalendarEvent {
        CalendarEvent(
            title: title,
            start: start.map { Date(timeIntervalSince1970: $0) },
            end: end.map { Date(timeIntervalSince1970: $0) },
            isAllDay: allDay,
            isCancelled: cancelled
        )
    }
}

final class CalendarMeetingNameProviderTests: XCTestCase {
    func testReturnsTitleFromSource() async {
        let provider = CalendarMeetingNameProvider(source: StubSource(events: [
            CalendarEvent(title: "Roadmap", start: Date(timeIntervalSince1970: 0),
                          end: Date(timeIntervalSince1970: 10000), isAllDay: false, isCancelled: false)
        ]))
        let name = await provider.meetingName(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(name, "Roadmap")
    }

    func testFailingCalendarReturnsNilWithoutThrowing() async {
        let provider = CalendarMeetingNameProvider(source: FailingSource())
        let name = await provider.meetingName(at: Date())
        XCTAssertNil(name)
    }

    func testSlowCalendarIsAbandonedAtTheDeadline() async {
        let provider = CalendarMeetingNameProvider(source: SlowSource(), deadline: .milliseconds(50))
        let started = Date()
        let name = await provider.meetingName(at: Date())
        XCTAssertNil(name)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    private struct StubSource: CalendarEventSource {
        let events: [CalendarEvent]
        func events(from _: Date, to _: Date) async throws -> [CalendarEvent] {
            events
        }
    }

    private struct FailingSource: CalendarEventSource {
        func events(from _: Date, to _: Date) async throws -> [CalendarEvent] {
            throw GoogleCalendarError.notConnected
        }
    }

    private struct SlowSource: CalendarEventSource {
        func events(from _: Date, to _: Date) async throws -> [CalendarEvent] {
            try await Task.sleep(for: .seconds(30))
            return []
        }
    }
}

final class MeetingFileNameTests: XCTestCase {
    func testReservedAndControlCharactersBecomeSpaces() {
        XCTAssertEqual(MeetingFileName.stem(from: "Design: review/Q3"), "Design review Q3")
        XCTAssertEqual(MeetingFileName.stem(from: "Notes\u{0}with\tcontrol\nchars"), "Notes with control chars")
    }

    func testPathTraversalCannotEscapeTheFolder() {
        XCTAssertEqual(MeetingFileName.stem(from: "../../etc"), "etc")
    }

    func testBlankOrDotOnlyTitlesFallBack() {
        XCTAssertNil(MeetingFileName.stem(from: nil))
        XCTAssertNil(MeetingFileName.stem(from: "   "))
        XCTAssertNil(MeetingFileName.stem(from: "..."))
    }

    func testLongTitlesAreCapped() {
        let stem = MeetingFileName.stem(from: String(repeating: "a", count: 200))
        XCTAssertEqual(stem?.count, MeetingFileName.maximumLength)
    }

    func testReadableCasingIsPreserved() {
        XCTAssertEqual(MeetingFileName.stem(from: "Weekly Sync (Team A)"), "Weekly Sync (Team A)")
    }
}

final class GoogleCalendarConfigurationTests: XCTestCase {
    func testDesktopClientIDIsAcceptedWithOrWithoutSecret() throws {
        let withSecret = try XCTUnwrap(GoogleCalendarConfiguration(
            clientID: "1234-abc.apps.googleusercontent.com",
            clientSecret: " GOCSPX-test \n"
        ))
        XCTAssertEqual(withSecret.clientSecret, "GOCSPX-test")

        let withoutSecret = try XCTUnwrap(GoogleCalendarConfiguration(
            clientID: "1234-abc.apps.googleusercontent.com",
            clientSecret: ""
        ))
        XCTAssertNil(withoutSecret.clientSecret)
    }

    func testEmptyOrNonGoogleClientIDsAreRejected() {
        XCTAssertNil(GoogleCalendarConfiguration(clientID: "", clientSecret: nil))
        XCTAssertNil(GoogleCalendarConfiguration(clientID: "unconfigured", clientSecret: nil))
        XCTAssertNil(GoogleCalendarConfiguration(clientID: ".apps.googleusercontent.com", clientSecret: nil))
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        let request = GoogleOAuthCodeRequest(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                                             state: "state")
        XCTAssertEqual(request.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedRequestsAreUniqueAndURLSafe() {
        let first = GoogleOAuthCodeRequest.make()
        let second = GoogleOAuthCodeRequest.make()
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertFalse(first.codeVerifier.contains { "+/=".contains($0) })
        XCTAssertFalse(first.state.contains { "+/=".contains($0) })
    }
}
