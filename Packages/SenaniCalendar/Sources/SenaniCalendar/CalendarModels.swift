import Foundation

/// A half-open query window [start, end).
public struct DateRange: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// One busy block returned by the freeBusy API.
public struct FreeBusyInterval: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// A listed calendar event (from events.list).
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public init(id: String, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

/// A proposed free slot the Booking agent can offer.
public struct CalendarSlot: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A DRAFT for a tentative hold. Built by `CalendarClient.proposeHold(...)` but NEVER inserted
/// in Phase 2 (writing it needs a new SenaniRules.Action case — §5). It carries everything a
/// future hold-write would need.
public struct TentativeHoldDraft: Sendable, Equatable {
    public let calendarId: String
    public let title: String
    public let start: Date
    public let end: Date
    public init(calendarId: String, title: String, start: Date, end: Date) {
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
    }
}
