import Testing
import Foundation
import SenaniRules
import SenaniAnalytics
@testable import SenaniDigest

@Suite struct DigestEmailTests {
    private func sampleReport() -> DigestReport {
        DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 3, outboundCount: 1,
            topSenders: [SenderCount(sender: "alice@x.com", count: 2)],
            topDomains: [DomainCount(domain: "x.com", count: 2)],
            medianReplyLatencySeconds: 120, replyCount: 1,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1)],
            pendingApprovals: 4
        )
    }

    @Test func composesAnOutboundSendAction() {
        let action = DigestEmailComposer.action(for: sampleReport())
        guard case let .send(body) = action else {
            Issue.record("expected .send, got \(action)"); return
        }
        #expect(action.actionClass == .outbound)
        #expect(body.contains("3"))   // inbound count appears in the body
        #expect(body.contains("alice@x.com"))
    }

    @Test func outboundActionAlwaysQueuesUnderEveryAutonomy() {
        let action = DigestEmailComposer.action(for: sampleReport())
        #expect(ActionRouter.route(action, autonomy: .auto) == .queuedForApproval)
        #expect(ActionRouter.route(action, autonomy: .prepare) == .queuedForApproval)
        #expect(ActionRouter.route(action, autonomy: .ask) == .queuedForApproval)
    }
}
