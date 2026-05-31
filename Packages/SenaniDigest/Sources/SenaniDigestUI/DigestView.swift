import SwiftUI
import SenaniRules
import SenaniDigest
import SenaniDesign
import SenaniAnalytics

/// Pure, testable formatting seam for the DigestView (no SwiftUI types).
public struct DigestViewModel: Sendable, Equatable {
    public let headline: String
    public let pendingApprovalsLabel: String
    public let replyLatencyLabel: String
    public let topSenderLabels: [String]
    public let topDomainLabels: [String]
    public let automationLabels: [String]
    /// The outbound "email me the digest" action (never auto-sends; routes to approval).
    public let emailAction: Action

    public init(report: DigestReport) {
        headline = "\(report.inboundCount) in · \(report.outboundCount) sent"
        pendingApprovalsLabel = "\(report.pendingApprovals) pending approvals"
        if report.replyCount > 0 {
            let minutes = Int((report.medianReplyLatencySeconds / 60).rounded())
            replyLatencyLabel = "Median reply: \(minutes) min"
        } else {
            replyLatencyLabel = "No replies today"
        }
        topSenderLabels = report.topSenders.map { "\($0.sender) — \($0.count)" }
        topDomainLabels = report.topDomains.map { "\($0.domain) — \($0.count)" }
        automationLabels = report.ruleActivity.map {
            "\($0.ruleId): \($0.executed)/\($0.prepared)/\($0.queuedForApproval)"
        }
        emailAction = DigestEmailComposer.action(for: report)
    }
}

/// The gold-glass Daily Digest surface — the digest's primary view. Renders a
/// DigestReport in a GlassPanel and offers "Email me the digest", which hands
/// the OUTBOUND action to the injected host (the composition root queues it; the
/// view never sends mail itself).
public struct DigestView: View {
    private let model: DigestViewModel
    private let onEmailDigest: (Action) -> Void

    public init(report: DigestReport, onEmailDigest: @escaping (Action) -> Void) {
        self.model = DigestViewModel(report: report)
        self.onEmailDigest = onEmailDigest
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily Digest")
                    .font(.senaniTitle)
                    .foregroundStyle(Color.senaniInk)

                Text(model.headline)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniAccent)

                Text(model.replyLatencyLabel)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniMuted)

                section("Top senders", items: model.topSenderLabels)
                section("Top domains", items: model.topDomainLabels)
                section("Automations", items: model.automationLabels)

                Text(model.pendingApprovalsLabel)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniMuted)

                Button("Email me the digest") {
                    onEmailDigest(model.emailAction)
                }
                .font(.senaniBody)
                .foregroundStyle(Gold.base)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.senaniBody).foregroundStyle(Color.senaniInk)
                ForEach(items, id: \.self) { item in
                    Text(item).font(.senaniBody).foregroundStyle(Color.senaniMuted)
                }
            }
        }
    }
}

#Preview("DigestView") {
    DigestView(
        report: DigestReport(
            day: Date(),
            inboundCount: 12, outboundCount: 4,
            topSenders: [SenderCount(sender: "alice@example.com", count: 7)],
            topDomains: [DomainCount(domain: "example.com", count: 7)],
            medianReplyLatencySeconds: 3_600, replyCount: 3,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 5, prepared: 1, queuedForApproval: 2)],
            pendingApprovals: 6
        ),
        onEmailDigest: { _ in }
    )
    .frame(width: 360)
    .padding()
}
