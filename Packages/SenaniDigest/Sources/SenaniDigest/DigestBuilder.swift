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

        // Reply latency: median of the per-inbound seconds for THIS day only.
        // AnalyticsQueries (frozen) exposes only a `since:` floor, so building for a
        // PAST day would otherwise fold in every later day's replies. We bound the
        // window to [utcDayStart, utcNextDayStart) by subtracting the "since next
        // midnight" result set (the rows belonging to later days) from the "since
        // this midnight" set. ReplyLatency carries no timestamp, but each row is keyed
        // by its inbound thread, so set-differencing on threadId yields exactly the
        // inbounds whose date < utcNextDayStart.
        let dayLatencies = try analytics.replyLatency(since: window.utcDayStart)
        let laterThreadIds = Set(
            try analytics.replyLatency(since: window.utcNextDayStart).map(\.threadId)
        )
        let latencies = dayLatencies
            .filter { !laterThreadIds.contains($0.threadId) }
            .map(\.seconds)
        let (median, count) = Self.median(of: latencies)

        // Rule/agent activity for THIS day only. Same `since:`-floor problem: subtract
        // the per-rule counts logged on later days (>= utcNextDayStart) from the counts
        // logged since this midnight, leaving only this day's [utcDayStart, utcNextDayStart).
        let ruleActivity = Self.dayScopedRuleActivity(
            since: try analytics.ruleActivity(since: window.utcDayStart),
            later: try analytics.ruleActivity(since: window.utcNextDayStart)
        )

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

    /// Day-scope rule activity by subtracting later-day per-rule counts from the
    /// "since day start" aggregates. `since` is grouped by ruleId since `utcDayStart`;
    /// `later` is the same grouped since `utcNextDayStart`. The difference is exactly
    /// this day's window. Rules that net to zero across all three counters are dropped.
    static func dayScopedRuleActivity(
        since: [RuleActivity],
        later: [RuleActivity]
    ) -> [RuleActivity] {
        let laterById = Dictionary(later.map { ($0.ruleId, $0) }, uniquingKeysWith: { a, _ in a })
        return since.compactMap { row in
            let after = laterById[row.ruleId]
            let executed = row.executed - (after?.executed ?? 0)
            let prepared = row.prepared - (after?.prepared ?? 0)
            let queued = row.queuedForApproval - (after?.queuedForApproval ?? 0)
            guard executed != 0 || prepared != 0 || queued != 0 else { return nil }
            return RuleActivity(
                ruleId: row.ruleId,
                executed: executed,
                prepared: prepared,
                queuedForApproval: queued
            )
        }
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
