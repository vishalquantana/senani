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
}
