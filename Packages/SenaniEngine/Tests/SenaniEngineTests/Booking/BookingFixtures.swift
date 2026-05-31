import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniCalendar

enum BK {
    static let account = "ramesh@quantana.in"
    /// Fixed "now": Wed 2023-11-15 08:00:00 UTC. Tests use UTC business hours for determinism.
    static let now = CalendarHTTP.date(from: "2023-11-15T08:00:00Z")!
    static let utc = TimeZone(identifier: "UTC")!

    /// An incoming message explicitly triaged into the Booking category (label).
    static func bookingLabeled(
        id: String = "m-book",
        from: String = "sarah@client.com",
        subject: String = "Can we meet next week?",
        body: String = "Hi Ramesh, do you have 30 minutes to discuss the proposal?",
        threadId: String = "t1"
    ) -> Message {
        Message(id: id, from: from, to: [account], subject: subject, body: body,
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [TriageCategory.booking.label],
                threadId: threadId, date: now, isFromUser: false)
    }

    /// An incoming message with meeting-intent wording but NO Booking label.
    static func meetingIntent(
        subject: String = "Quick call?",
        body: String = "Could we schedule a call to sync on timelines?"
    ) -> Message {
        Message(id: "m-intent", from: "sarah@client.com", to: [account], subject: subject, body: body,
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t2", date: now, isFromUser: false)
    }

    /// An unrelated message: no Booking label, no meeting wording.
    static func unrelated() -> Message {
        Message(id: "m-other", from: "newsletter@x.com", to: [account], subject: "Your weekly digest",
                body: "Here are this week's top stories.", hasAttachment: false,
                listUnsubscribeHeader: "<mailto:u@x.com>", labels: ["Newsletter"],
                threadId: "t3", date: now, isFromUser: false)
    }

    static func context(_ message: Message) -> AgentContext {
        AgentContext(account: account, thread: [message], rules: [],
                     retrieve: { _, _ in [] }, now: now, pipeline: InMemoryPipelineStore())
    }

    /// Busy on Wed 09:00–10:00 and 13:00–14:00 UTC (mirrors CalendarClient fixtures).
    static func cannedBusy() -> [FreeBusyInterval] {
        [FreeBusyInterval(start: CalendarHTTP.date(from: "2023-11-15T09:00:00Z")!,
                          end: CalendarHTTP.date(from: "2023-11-15T10:00:00Z")!),
         FreeBusyInterval(start: CalendarHTTP.date(from: "2023-11-15T13:00:00Z")!,
                          end: CalendarHTTP.date(from: "2023-11-15T14:00:00Z")!)]
    }
}
