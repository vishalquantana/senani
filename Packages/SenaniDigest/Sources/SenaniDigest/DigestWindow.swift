import Foundation

/// The day-scoped bounds for a digest, computed from the *injected calendar's*
/// start-of-day so the window aligns with the LOCAL calendar day that
/// `DigestScheduler` fires on (it also keys off `calendar.startOfDay(for:)`).
///
/// Previously this bucketed in UTC (floor(date/86400)) and ignored the calendar,
/// which offset the window for any non-UTC user — the scheduler would fire for the
/// local day while the digest aggregated a different UTC day. We now honor the
/// calendar so the two agree.
///
/// The property names retain the `utc`-prefixed spelling for API stability and
/// because, with a UTC calendar (the canonical configuration matching
/// `volumeByDay`'s UTC day buckets), these instants ARE UTC midnights and remain
/// the bucket key shared with `VolumePoint.day`. With a non-UTC calendar they are
/// the local-day boundaries expressed as absolute instants.
public struct DigestWindow: Sendable, Equatable {
    /// Start-of-day of the day containing the instant, per the injected calendar.
    /// With a UTC calendar this is the UTC-midnight `VolumePoint.day` bucket key.
    public let utcDayStart: Date
    /// Exclusive upper bound — the start of the next calendar day.
    public let utcNextDayStart: Date

    public init(containing instant: Date, calendar: Calendar) {
        // Honor the injected calendar's timezone so the window matches the LOCAL day
        // DigestScheduler fires for, rather than a fixed UTC bucket.
        let start = calendar.startOfDay(for: instant)
        self.utcDayStart = start
        // Use calendar arithmetic (not +86400) so DST day-length changes are handled.
        self.utcNextDayStart = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
    }
}
