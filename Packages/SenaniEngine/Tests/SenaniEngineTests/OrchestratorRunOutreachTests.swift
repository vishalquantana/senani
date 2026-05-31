import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

// Last audit follow-up: the user-initiated, list-driven Outreach trigger. The Orchestrator
// builds the AgentContext + AgentTools the same way it does internally, calls the injected
// OutreachAgent to produce [OutreachProposal], and enqueues each via the existing
// enqueueOutreach path. SINGLE SAFETY INVARIANT: outreach proposals are OUTBOUND → always
// queued for approval, NEVER executed/sent to the mail backend.

@Suite struct OrchestratorRunOutreachTests {
    private func makeOrchestrator(_ h: EngineHarness) -> Orchestrator {
        let agent = OutreachAgent(
            generator: h.generator,
            voice: FakeVoicePrefixProvider(prefix: "VOICE"),
            policy: OutreachPolicy(cooldownDays: 7, maxPerRun: 25))
        return Orchestrator(
            registry: AgentRegistry(agents: []),
            triage: FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in false }, emit: { _, _, _ in [] }),
            mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
            messages: h.messages, index: h.index, embedder: h.embedder,
            generator: h.generator, pipeline: h.pipeline, rules: h.rules,
            outreachAgent: agent, account: { "me@x.com" }, now: h.now)
    }

    @Test func openDormantTargetQueuesAProposalWithPreservedRecipient() async throws {
        let h = try EngineHarness()
        await h.generator.preload("Hi there, quick idea.")
        let orch = makeOrchestrator(h)

        let target = OutreachTarget(
            contactEmail: "prospect@acme.com",
            deal: Deal(id: "prospect@acme.com", contactEmail: "prospect@acme.com",
                       company: "Acme", stage: .qualified, score: 70, value: nil,
                       lastTouch: h.now().addingTimeInterval(-30 * 86_400), sourceMessageId: nil),
            thread: [])

        let outcomes = try await orch.runOutreach(to: [target])

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.outcome == .queuedForApproval)

        // A Proposal lands in the ApprovalStore with the recipient preserved.
        let pending = try h.approvals.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.proposal.message.to == ["prospect@acme.com"])
        #expect(pending.first?.proposal.message.from == "me@x.com")
        #expect(pending.first?.proposal.trigger == .rule(id: "outreach"))
        if case .send = pending.first?.proposal.action {} else {
            Issue.record("expected an outbound .send action")
        }
    }

    @Test func zeroTargetsIsANoOp() async throws {
        let h = try EngineHarness()
        let orch = makeOrchestrator(h)

        let outcomes = try await orch.runOutreach(to: [])

        #expect(outcomes.isEmpty)
        #expect(try h.approvals.pending().isEmpty)
        let prompts = await h.generator.recordedPrompts
        #expect(prompts.isEmpty)
    }

    @Test func outreachIsNeverAppliedToTheMailBackend() async throws {
        let h = try EngineHarness()
        await h.generator.preload("Reactivation nudge.")
        let orch = makeOrchestrator(h)

        let target = OutreachTarget(
            contactEmail: "stale@x.com",
            deal: Deal(id: "stale@x.com", contactEmail: "stale@x.com",
                       company: "Acme", stage: .negotiation, score: 60, value: nil,
                       lastTouch: h.now().addingTimeInterval(-45 * 86_400), sourceMessageId: nil),
            thread: [])

        _ = try await orch.runOutreach(to: [target])

        // SAFETY INVARIANT: outbound outreach is never sent — the backend is never called.
        let applied = await h.backend.applied
        #expect(applied.isEmpty)
        #expect(try h.approvals.pending().count == 1)
    }
}
