import Testing
import Foundation
@testable import SenaniEngine
import SenaniCalendar

@Suite struct BookingSlotSelectionTests {
    private func d(_ s: String) -> Date { CalendarHTTP.date(from: s)! }

    @Test func picksThreeNonConflictingBusinessHoursSlots() {
        // now = Wed 08:00Z (before business hours). Busy 09:00–10:00 and 13:00–14:00.
        // First three free 30-min slots from 09:00 grid: 10:00, 10:30, 11:00.
        let slots = BookingAgent.pickSlots(
            now: BK.now,
            busy: BK.cannedBusy(),
            config: .default,
            timeZone: BK.utc
        )
        #expect(slots.count == 3)
        #expect(slots[0].start == d("2023-11-15T10:00:00Z"))
        #expect(slots[1].start == d("2023-11-15T10:30:00Z"))
        #expect(slots[2].start == d("2023-11-15T11:00:00Z"))
        // Each is exactly slotMinutes long.
        #expect(slots.allSatisfy { $0.duration == 30 * 60 })
        // None overlaps a busy interval.
        for s in slots {
            for b in BK.cannedBusy() {
                #expect(!(s.start < b.end && b.start < s.end))
            }
        }
    }

    @Test func skipsSlotsStartingInThePast() {
        // now = Wed 11:15Z → the 11:00 slot is partly past; first candidate is 11:30.
        let now = d("2023-11-15T11:15:00Z")
        let slots = BookingAgent.pickSlots(now: now, busy: BK.cannedBusy(), config: .default, timeZone: BK.utc)
        #expect(slots.first?.start == d("2023-11-15T11:30:00Z"))
        #expect(slots.allSatisfy { $0.start >= now })
    }

    @Test func rollsToTheNextBusinessDayWhenADayHasTooFewSlots() {
        // Busy the entire Wed business day → all three slots fall on Thu starting 09:00.
        let fullDay = [FreeBusyInterval(start: d("2023-11-15T09:00:00Z"), end: d("2023-11-15T17:00:00Z"))]
        let slots = BookingAgent.pickSlots(now: BK.now, busy: fullDay, config: .default, timeZone: BK.utc)
        #expect(slots.count == 3)
        #expect(slots[0].start == d("2023-11-16T09:00:00Z"))
        #expect(slots[1].start == d("2023-11-16T09:30:00Z"))
    }

    @Test func returnsFewerThanRequestedWhenWindowIsExhausted() {
        // searchDays = 1 and the whole day is busy → no slots.
        let fullDay = [FreeBusyInterval(start: d("2023-11-15T09:00:00Z"), end: d("2023-11-15T17:00:00Z"))]
        let cfg = SlotConfig(slotMinutes: 30, businessStartHour: 9, businessEndHour: 17, searchDays: 1, slotsToPropose: 3)
        let slots = BookingAgent.pickSlots(now: BK.now, busy: fullDay, config: cfg, timeZone: BK.utc)
        #expect(slots.isEmpty)
    }
}
