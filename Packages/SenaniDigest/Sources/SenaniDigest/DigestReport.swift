import Foundation
import SenaniAnalytics

/// One day's aggregated inbox activity — the typed payload the DigestView renders
/// and the "email me the digest" action composes from. Reuses SenaniAnalytics
/// result types verbatim (SenderCount/DomainCount/RuleActivity) so there is no
/// lossy re-mapping between the query layer and the digest.
public struct DigestReport: Sendable, Equatable {
    /// UTC midnight of the digest day (the bucket key shared with VolumePoint.day).
    public let day: Date
    /// Inbound messages received during the day.
    public let inboundCount: Int
    /// Messages the user sent during the day.
    public let outboundCount: Int
    /// Top inbound senders for the day, descending.
    public let topSenders: [SenderCount]
    /// Top inbound sender domains for the day, descending.
    public let topDomains: [DomainCount]
    /// Median seconds-to-first-reply across the day's replied threads (0 when replyCount == 0).
    public let medianReplyLatencySeconds: Double
    /// Number of inbound→reply transitions that contributed to the median.
    public let replyCount: Int
    /// Per-rule/agent automation activity for the day (from actions_log).
    public let ruleActivity: [RuleActivity]
    /// Count of proposals still awaiting the user's approval (point-in-time, not day-scoped).
    public let pendingApprovals: Int

    public init(
        day: Date,
        inboundCount: Int,
        outboundCount: Int,
        topSenders: [SenderCount],
        topDomains: [DomainCount],
        medianReplyLatencySeconds: Double,
        replyCount: Int,
        ruleActivity: [RuleActivity],
        pendingApprovals: Int
    ) {
        self.day = day
        self.inboundCount = inboundCount
        self.outboundCount = outboundCount
        self.topSenders = topSenders
        self.topDomains = topDomains
        self.medianReplyLatencySeconds = medianReplyLatencySeconds
        self.replyCount = replyCount
        self.ruleActivity = ruleActivity
        self.pendingApprovals = pendingApprovals
    }
}
