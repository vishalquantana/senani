import Foundation
import SenaniRules

/// Turns a DigestReport into a single OUTBOUND email action. `.send` is
/// `.outbound`, so `ActionRouter.route` forces `.queuedForApproval` under every
/// autonomy — the digest email can never auto-send. The composer is pure: it
/// formats the body and returns the action; it never touches a MailBackend.
public enum DigestEmailComposer {
    public static func action(for report: DigestReport) -> Action {
        .send(body: body(for: report))
    }

    /// Plain-text digest body. Deterministic; no locale-dependent formatting.
    static func body(for report: DigestReport) -> String {
        var lines: [String] = []
        lines.append("Senani — Daily Digest")
        lines.append("Inbound: \(report.inboundCount)  ·  Sent: \(report.outboundCount)")
        if report.replyCount > 0 {
            lines.append("Median reply latency: \(Int(report.medianReplyLatencySeconds))s over \(report.replyCount) reply(ies)")
        }
        if !report.topSenders.isEmpty {
            lines.append("Top senders:")
            for s in report.topSenders { lines.append("  • \(s.sender) (\(s.count))") }
        }
        if !report.topDomains.isEmpty {
            lines.append("Top domains:")
            for d in report.topDomains { lines.append("  • \(d.domain) (\(d.count))") }
        }
        if !report.ruleActivity.isEmpty {
            lines.append("Automations:")
            for r in report.ruleActivity {
                lines.append("  • \(r.ruleId): \(r.executed) done, \(r.prepared) prepared, \(r.queuedForApproval) queued")
            }
        }
        lines.append("Pending approvals: \(report.pendingApprovals)")
        return lines.joined(separator: "\n")
    }
}
