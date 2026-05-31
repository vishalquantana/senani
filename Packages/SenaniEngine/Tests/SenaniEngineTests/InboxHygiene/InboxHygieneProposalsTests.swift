import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InboxHygieneProposalsTests {
    private let agent = InboxHygieneAgent()

    @Test func emitsReversibleDeclutterSetForBulkMail() async throws {
        let m = IH.newsletter()
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools(generator: FakeTextGenerator()))
        // Declutter: label + markRead + archive, all reversible.
        #expect(actions.contains(.label("Senani/Newsletter")))
        #expect(actions.contains(.markRead))
        #expect(actions.contains(.archive))
        for a in actions where a.actionClass == .reversible {
            #expect([.label("Senani/Newsletter"), .markRead, .archive].contains(a))
        }
    }

    @Test func mailtoHeaderProducesOneOutboundUnsubscribeReplyThatWillQueue() async throws {
        let m = IH.newsletter(listUnsubscribeHeader: "<mailto:unsub@brand.com>")
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools(generator: FakeTextGenerator()))
        let outbound = actions.filter { $0.actionClass == .outbound }
        #expect(outbound.count == 1)
        // The single outbound action is a reply (always queues) — never auto-sent.
        guard case let .reply(body) = outbound[0] else { Issue.record("expected .reply"); return }
        #expect(body.lowercased().contains("unsubscribe"))
        // Safety: ActionRouter queues it regardless of autonomy.
        #expect(SenaniRules.ActionRouter.route(outbound[0], autonomy: .auto) == .queuedForApproval)
    }

    @Test func httpsOnlyHeaderEmitsNoOutboundActionButRecordsTheTarget() async throws {
        // No mailto → no outbound reply (the https one-click POST is a §5 capability, not built).
        let m = IH.newsletter(listUnsubscribeHeader: "<https://brand.com/u/abc123>")
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools(generator: FakeTextGenerator()))
        #expect(actions.filter { $0.actionClass == .outbound }.isEmpty)   // nothing auto-unsubscribes
        // Still declutters.
        #expect(actions.contains(.archive))
        // The finding surfaces the https target for the UI / §5 capability.
        let finding = agent.finding(for: m, context: IH.context(thread: [m]))
        #expect(finding.httpsUnsubscribe == "https://brand.com/u/abc123")
        #expect(finding.mailtoUnsubscribe == nil)
        #expect(finding.oneClickUnsupported == true)   // flag for the human/UI
    }

    @Test func findingCapturesMailtoTargetForApprovalRouting() async throws {
        let m = IH.newsletter(listUnsubscribeHeader: "<mailto:unsub@brand.com?subject=bye>, <https://brand.com/u/x>")
        let finding = agent.finding(for: m, context: IH.context(thread: [m]))
        #expect(finding.mailtoUnsubscribe == "unsub@brand.com")
        #expect(finding.httpsUnsubscribe == "https://brand.com/u/x")
        #expect(finding.oneClickUnsupported == true)
    }

    @Test func noBulkSignalYieldsNoProposals() async throws {
        let m = IH.personal()
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools(generator: FakeTextGenerator()))
        #expect(actions.isEmpty)   // wakesFor is false → defensive empty result
    }

    @Test func neverEmitsMoreThanOneOutboundAction() async throws {
        // Even with both forms present, exactly one outbound (the mailto reply) is proposed.
        let m = IH.newsletter()   // header has BOTH mailto + https
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools(generator: FakeTextGenerator()))
        #expect(actions.filter { $0.actionClass == .outbound }.count == 1)
    }
}
