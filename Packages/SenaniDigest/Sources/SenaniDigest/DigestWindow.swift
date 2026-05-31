import Foundation

/// The day-scoped bounds for a digest. v1 buckets analytics in UTC to match
/// `SenaniAnalytics.AnalyticsQueries.volumeByDay` (which uses UTC day buckets),
/// so `utcDayStart` is the canonical key shared with `VolumePoint.day`.
/// (Local-timezone bucketing is a documented follow-up; see §Out of scope.)
public struct DigestWindow: Sendable, Equatable {
    /// UTC midnight of the day containing the instant — the VolumePoint bucket key.
    public let utcDayStart: Date
    /// Exclusive UTC upper bound (next UTC midnight).
    public let utcNextDayStart: Date

    private static let secondsPerDay: TimeInterval = 86_400

    public init(containing instant: Date, calendar: Calendar) {
        // UTC bucketing independent of the injected calendar's zone, matching
        // volumeByDay's floor(date/86400)*86400. The calendar parameter is held
        // for future local bucketing and kept in the signature for API stability.
        _ = calendar
        let secs = instant.timeIntervalSince1970
        let dayIndex = (secs / Self.secondsPerDay).rounded(.down)
        let start = dayIndex * Self.secondsPerDay
        self.utcDayStart = Date(timeIntervalSince1970: start)
        self.utcNextDayStart = Date(timeIntervalSince1970: start + Self.secondsPerDay)
    }
}
