import Foundation

/// The parts of a calendar event Noty needs to name a recording.
struct CalendarEvent: Equatable, Sendable {
    let title: String?
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let isCancelled: Bool
}

protocol CalendarEventSource: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

/// Reads event titles and times from the primary Google calendar. Attendees are not requested.
struct GoogleCalendarEventSource: CalendarEventSource {
    private static let endpoint = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

    let account: GoogleCalendarAccount

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let token = try await account.validAccessToken()
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else {
            throw GoogleCalendarError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "fields", value: "items(summary,status,start,end)")
        ]
        guard let url = components.url else { throw GoogleCalendarError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3

        let (data, response) = try await account.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GoogleCalendarError.requestFailed(statusCode: http.statusCode)
        }
        let list: EventList
        do {
            list = try JSONDecoder().decode(EventList.self, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse
        }
        return (list.items ?? []).map(\.calendarEvent)
    }
}

private struct EventList: Decodable {
    let items: [EventItem]?
}

private struct EventItem: Decodable {
    let summary: String?
    let status: String?
    let start: EventTime?
    let end: EventTime?

    var calendarEvent: CalendarEvent {
        CalendarEvent(
            title: summary,
            start: start?.dateTime.flatMap(parseDateTime),
            end: end?.dateTime.flatMap(parseDateTime),
            isAllDay: start?.dateTime == nil,
            isCancelled: status == "cancelled"
        )
    }
}

private struct EventTime: Decodable {
    let dateTime: String?
}

private func parseDateTime(_ value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) {
        return date
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
}
