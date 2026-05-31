import Testing
import Foundation
import SenaniRules
import SenaniAnalytics
@testable import SenaniDigestUI
@testable import SenaniDigest

@Suite struct DigestViewModelTests {
    private func report() -> DigestReport {
        DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 12, outboundCount: 4,
            topSenders: [SenderCount(sender: "alice@x.com", count: 7)],
            topDomains: [DomainCount(domain: "x.com", count: 7)],
            medianReplyLatencySeconds: 3_600, replyCount: 3,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 5, prepared: 1, queuedForApproval: 2)],
            pendingApprovals: 6
        )
    }

    @Test func summarizesVolumeAndApprovals() {
        let vm = DigestViewModel(report: report())
        #expect(vm.headline.contains("12"))
        #expect(vm.headline.contains("4"))
        #expect(vm.pendingApprovalsLabel == "6 pending approvals")
    }

    @Test func formatsReplyLatencyAsMinutes() {
        let vm = DigestViewModel(report: report())
        #expect(vm.replyLatencyLabel == "Median reply: 60 min")   // 3600s -> 60 min
    }

    @Test func emptyLatencyShowsNoReplies() {
        var r = report()
        r = DigestReport(day: r.day, inboundCount: r.inboundCount, outboundCount: r.outboundCount,
                         topSenders: r.topSenders, topDomains: r.topDomains,
                         medianReplyLatencySeconds: 0, replyCount: 0,
                         ruleActivity: r.ruleActivity, pendingApprovals: r.pendingApprovals)
        let vm = DigestViewModel(report: r)
        #expect(vm.replyLatencyLabel == "No replies today")
    }

    @Test func emailActionIsTheOutboundSend() {
        let vm = DigestViewModel(report: report())
        #expect(vm.emailAction.actionClass == .outbound)
    }
}
