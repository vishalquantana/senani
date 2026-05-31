import Testing
import Foundation
@testable import SenaniDigest

@Suite struct DigestSchedulerTests {
    // A thread-safe mutable clock the tests advance by hand.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval
        init(_ t: TimeInterval) { self.t = t }
        func set(_ t: TimeInterval) { lock.lock(); self.t = t; lock.unlock() }
        var now: @Sendable () -> Date {
            { [self] in lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: t) }
        }
    }

    // Records the dates onFire was invoked with.
    actor FireRecorder {
        private(set) var fires: [Date] = []
        func record(_ d: Date) { fires.append(d) }
    }

    private func makeScheduler(clock: MutableClock, recorder: FireRecorder,
                               lowPower: @escaping @Sendable () -> Bool = { false })
    -> DigestScheduler {
        DigestScheduler(
            hour: 8, minute: 0,
            calendar: DigestFixture.utcCalendar,
            now: clock.now,
            isLowPower: lowPower,
            onFire: { d in await recorder.record(d) }
        )
    }

    @Test func doesNotFireBeforeConfiguredTime() async throws {
        // 2026-03-15 07:00 UTC — before 08:00.
        let clock = MutableClock(DigestFixture.dayStart + 7 * 3600)
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()
        #expect(await recorder.fires.isEmpty)
    }

    @Test func firesOnceAtOrAfterConfiguredTime() async throws {
        // 2026-03-15 08:30 UTC — after 08:00.
        let clock = MutableClock(DigestFixture.dayStart + 8 * 3_600 + 1_800)
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()
        await scheduler.tick()   // second tick same day must NOT re-fire
        #expect(await recorder.fires.count == 1)
    }

    @Test func firesAgainOnTheNextDay() async throws {
        let clock = MutableClock(DigestFixture.dayStart + 8 * 3_600 + 1_800) // day 1, 08:30
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()                                              // fires day 1
        clock.set(DigestFixture.dayStart + 86_400 + 8 * 3_600 + 60)         // day 2, 08:01
        await scheduler.tick()                                              // fires day 2
        #expect(await recorder.fires.count == 2)
    }

    @Test func lowPowerSuppressesTheFire() async throws {
        let clock = MutableClock(DigestFixture.dayStart + 9 * 3_600) // 09:00, past 08:00
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder, lowPower: { true })
        await scheduler.tick()
        #expect(await recorder.fires.isEmpty)
    }
}
