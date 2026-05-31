import Foundation

/// Fires a daily-digest callback at most once per LOCAL calendar day, the first
/// time the injected clock has reached/passed the configured time-of-day, while
/// not on low power. This is DELIBERATELY separate from SenaniEngine.Scheduler
/// (the per-tick Gmail sync+process loop): a digest is a once-a-day timer, a
/// different cadence and trigger, so we do NOT add a hook to the frozen
/// SenaniEngine.Scheduler contract. The host composes the two if it wants one
/// timer surface. No real timers run in tests — `tick()` is driven by a fake clock.
public actor DigestScheduler {
    private let hour: Int
    private let minute: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let isLowPower: @Sendable () -> Bool
    private let onFire: @Sendable (Date) async -> Void
    private let checkInterval: TimeInterval

    /// The local calendar day (start-of-day Date) we last fired for, or nil.
    private var lastFiredDay: Date?
    private var loop: Task<Void, Never>?

    public init(
        hour: Int,
        minute: Int,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        isLowPower: @escaping @Sendable () -> Bool = { false },
        checkInterval: TimeInterval = 60,
        onFire: @escaping @Sendable (Date) async -> Void
    ) {
        self.hour = hour
        self.minute = minute
        self.calendar = calendar
        self.now = now
        self.isLowPower = isLowPower
        self.checkInterval = checkInterval
        self.onFire = onFire
    }

    /// One evaluation cycle. Fires onFire iff: not low power, the clock has reached
    /// today's configured time, and we have not already fired for today.
    public func tick() async {
        let current = now()
        if isLowPower() { return }

        let dayStart = calendar.startOfDay(for: current)
        guard let fireInstant = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: dayStart
        ) else { return }

        guard current >= fireInstant else { return }
        guard lastFiredDay != dayStart else { return }

        lastFiredDay = dayStart
        await onFire(current)
    }

    /// Schedule repeating `tick()`s every `checkInterval` seconds.
    public func start() async {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let nanos = await self.intervalNanos()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Cancel the repeating loop.
    public func stop() async {
        loop?.cancel()
        loop = nil
    }

    private func intervalNanos() -> UInt64 {
        UInt64(max(0, checkInterval) * 1_000_000_000)
    }
}
