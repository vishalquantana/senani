import Testing
import Foundation
@testable import SenaniDigest

@Suite struct DigestWindowTests {
    @Test func utcDayStartIsMidnightOfTheGivenInstant() {
        // An instant mid-day on 2026-03-15.
        let midDay = Date(timeIntervalSince1970: DigestFixture.dayStart + 50_000)
        let window = DigestWindow(containing: midDay, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == Date(timeIntervalSince1970: DigestFixture.dayStart))
    }

    @Test func endIsExclusiveNextMidnight() {
        let midDay = Date(timeIntervalSince1970: DigestFixture.dayStart + 1)
        let window = DigestWindow(containing: midDay, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(window.utcNextDayStart == Date(timeIntervalSince1970: DigestFixture.nextDayStart))
    }

    @Test func instantExactlyAtMidnightBelongsToThatDay() {
        let exactly = Date(timeIntervalSince1970: DigestFixture.dayStart)
        let window = DigestWindow(containing: exactly, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == exactly)
    }

    @Test func honorsInjectedCalendarForLocalDayBoundaries() {
        // FINDING 2: DigestWindow must honor the injected calendar so the window
        // aligns with the LOCAL day DigestScheduler fires on. With a UTC+5:30
        // (IST) calendar, an instant at 2026-03-15 02:00 UTC is already
        // 2026-03-15 07:30 LOCAL, so its local day starts at the *previous* UTC
        // midnight minus the offset: 2026-03-14 18:30 UTC.
        var ist = Calendar(identifier: .gregorian)
        ist.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!  // +05:30
        let instant = Date(timeIntervalSince1970: DigestFixture.dayStart + 2 * 3600) // 02:00 UTC
        let window = DigestWindow(containing: instant, calendar: ist)

        let expectedStart = ist.startOfDay(for: instant)
        #expect(window.utcDayStart == expectedStart)
        #expect(window.utcNextDayStart == ist.date(byAdding: .day, value: 1, to: expectedStart)!)
        // And it is genuinely local-aligned: 2026-03-14 18:30:00 UTC.
        #expect(window.utcDayStart == Date(timeIntervalSince1970: DigestFixture.dayStart - 5 * 3600 - 1800))
    }
}
