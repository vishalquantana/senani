import Testing
import Foundation
@testable import SenaniCalendar

@Test func dateRangeAndIntervalsAreValueTypes() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(3_600)
    let range = DateRange(start: start, end: end)
    #expect(range.start == start)
    #expect(range.end == end)

    let busy = FreeBusyInterval(start: start, end: end)
    #expect(busy == FreeBusyInterval(start: start, end: end))

    let slot = CalendarSlot(start: start, end: end)
    #expect(slot.duration == 3_600)

    let event = CalendarEvent(id: "e1", title: "Sync", start: start, end: end)
    #expect(event.title == "Sync")

    let draft = TentativeHoldDraft(calendarId: "primary", title: "Hold: Sarah", start: start, end: end)
    #expect(draft.calendarId == "primary")
    #expect(draft.title == "Hold: Sarah")
}
