import Foundation
import SenaniAnalytics

/// Pure day-scoped aggregator. Reads the canonical store ONLY through
/// `SenaniAnalytics.AnalyticsQueries` (and the `ApprovalReading` seam for the
/// pending count). No writes, no network, no model. Deterministic over the
/// injected dependencies + the date passed to `build(for:)`.
public struct DigestBuilder: Sendable {
    private let analytics: AnalyticsQueries
    private let approvals: any ApprovalReading
    private let calendar: Calendar
    private let topLimit: Int

    public init(
        analytics: AnalyticsQueries,
        approvals: any ApprovalReading,
        calendar: Calendar,
        topLimit: Int = 5
    ) {
        self.analytics = analytics
        self.approvals = approvals
        self.calendar = calendar
        self.topLimit = topLimit
    }

    /// Build the report for the day containing `date`.
    public func build(for date: Date) throws -> DigestReport {
        let window = DigestWindow(containing: date, calendar: calendar)

        // Volume: the bucket whose day == this UTC day.
        let volume = try analytics.volumeByDay(since: window.utcDayStart)
        let today = volume.first { $0.day == window.utcDayStart }
        let inbound = today?.inbound ?? 0
        let outbound = today?.outbound ?? 0

        // Top lists (store-wide since the API has no upper bound — see reconciliation note).
        let topSenders = try analytics.topSenders(limit: topLimit)
        let topDomains = try analytics.topDomains(limit: topLimit)

        // Reply latency: median of the per-inbound seconds returned since day start.
        let latencies = try analytics.replyLatency(since: window.utcDayStart).map(\.seconds)
        let (median, count) = Self.median(of: latencies)

        // Rule/agent activity for the day.
        let ruleActivity = try analytics.ruleActivity(since: window.utcDayStart)

        // Pending approvals (point-in-time).
        let pending = try approvals.pendingCount()

        return DigestReport(
            day: window.utcDayStart,
            inboundCount: inbound,
            outboundCount: outbound,
            topSenders: topSenders,
            topDomains: topDomains,
            medianReplyLatencySeconds: median,
            replyCount: count,
            ruleActivity: ruleActivity,
            pendingApprovals: pending
        )
    }

    /// Median of a value array. Even counts average the two middles. Empty => (0, 0).
    static func median(of values: [Double]) -> (median: Double, count: Int) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return (sorted[n / 2], n)
        } else {
            return ((sorted[n / 2 - 1] + sorted[n / 2]) / 2, n)
        }
    }
}
