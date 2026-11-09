import Foundation

/// Supplies the title for a new recording. Returning nil keeps the timestamp name.
protocol MeetingNameProviding: Sendable {
    func meetingName(at date: Date) async -> String?
}

struct NoMeetingName: MeetingNameProviding {
    func meetingName(at _: Date) async -> String? {
        nil
    }
}

struct CalendarMeetingNameProvider: MeetingNameProviding {
    let source: CalendarEventSource
    var deadline: Duration = .seconds(3)

    /// Any event that started before `date` and is still running ends after `date`,
    /// so a window starting at `date` finds it regardless of its length.
    func meetingName(at date: Date) async -> String? {
        let source = source
        let events: [CalendarEvent]? = await withDeadline(deadline) {
            try? await source.events(from: date, to: date.addingTimeInterval(60))
        }
        guard let events else { return nil }
        return MeetingEventSelection.title(in: events, at: date)
    }
}

/// Returns the operation's result, or nil if it fails or misses the deadline.
func withDeadline<T: Sendable>(_ deadline: Duration,
                               _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: deadline)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

enum MeetingEventSelection {
    /// The timed, uncancelled, titled event covering `date`. If several overlap, the latest start wins.
    static func title(in events: [CalendarEvent], at date: Date) -> String? {
        let current = events.compactMap { event -> (title: String, start: Date)? in
            guard !event.isAllDay, !event.isCancelled,
                  let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let start = event.start, let end = event.end,
                  start <= date, date < end
            else { return nil }
            return (title, start)
        }
        return current.max { $0.start < $1.start }?.title
    }
}
