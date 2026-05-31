import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ProposalTrackerProposalsTests {
    private func agent(intent: String) -> ProposalTrackerAgent {
        ProposalTrackerAgent(classifier: ReplyIntentClassifier(
            generator: FakeTextGenerator(response: "{\"intent\":\"\(intent)\"}")))
    }

    // --- Proposal detected → Deal at .proposal with extracted value ---

    @Test func outboundProposalMovesDealToProposalWithValue() async throws {
        let pipeline = InMemoryPipelineStore()
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: pipeline, documentFields: ["total": "$12,000"])

        let actions = try await agent(intent: "other").proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(actions.isEmpty)                              // sending the proposal is not our action
        let deal = try #require(try pipeline.byContact(PT.client))
        #expect(deal.stage == .proposal)
        #expect(deal.value == 12000)
        #expect(deal.sourceMessageId == "m-out")
    }

    @Test func outboundProposalUpgradesAnExistingQualifiedDeal() async throws {
        let pipeline = InMemoryPipelineStore()
        try pipeline.upsert(PT.dealAt(.qualified))
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: pipeline, documentFields: ["amount": "30000"])

        _ = try await agent(intent: "other").proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))

        let deal = try #require(try pipeline.byContact(PT.client))
        #expect(deal.stage == .proposal)
        #expect(deal.value == 30000)
        #expect(deal.id == PT.client)                         // same row, not a duplicate
        #expect(try pipeline.all().count == 1)
    }

    // --- Replies move the stage ---

    @Test func acceptingReplyMovesDealToWon() async throws {
        let pipeline = InMemoryPipelineStore()
        try pipeline.upsert(PT.dealAt(.proposal, value: 12000))
        let reply = PT.inboundReply(body: "Approved, let's go!")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "accept").proposals(for: reply, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(try pipeline.byContact(PT.client)?.stage == .won)
        #expect(try pipeline.byContact(PT.client)?.value == 12000)   // value preserved
        // A won deal may emit an optional outbound nudge (thank-you / next-steps) — outbound queues.
        #expect(actions.allSatisfy { $0.actionClass == ActionClass.outbound })
    }

    @Test func decliningReplyMovesDealToLostWithNoNudge() async throws {
        let pipeline = InMemoryPipelineStore()
        try pipeline.upsert(PT.dealAt(.proposal))
        let reply = PT.inboundReply(body: "We've gone with another vendor.")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "decline").proposals(for: reply, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(try pipeline.byContact(PT.client)?.stage == .lost)
        #expect(actions.isEmpty)   // no nudge on a lost deal
    }

    @Test func ambiguousReplyMovesDealToNegotiation() async throws {
        let pipeline = InMemoryPipelineStore()
        try pipeline.upsert(PT.dealAt(.proposal))
        let reply = PT.inboundReply(body: "Thanks, we'll review internally and circle back.")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        _ = try await agent(intent: "other").proposals(for: reply, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(try pipeline.byContact(PT.client)?.stage == .negotiation)
    }

    @Test func negotiatingReplyMovesDealToNegotiationAndMayNudge() async throws {
        let pipeline = InMemoryPipelineStore()
        try pipeline.upsert(PT.dealAt(.proposal))
        let reply = PT.inboundReply(body: "Can you sharpen the price a bit?")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "negotiate").proposals(for: reply, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(try pipeline.byContact(PT.client)?.stage == .negotiation)
        #expect(actions.allSatisfy { $0.actionClass == ActionClass.outbound })   // any nudge always queues
    }

    // --- Non-proposal mail ignored ---

    @Test func nonProposalOutboundMakesNoPipelineChange() async throws {
        let pipeline = InMemoryPipelineStore()
        let m = PT.ordinaryOutbound()
        let ctx = PT.context(thread: [m], pipeline: pipeline)

        let actions = try await agent(intent: "other").proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(actions.isEmpty)
        #expect(try pipeline.all().isEmpty)
    }

    @Test func inboundReplyOnUntrackedThreadMakesNoChange() async throws {
        let pipeline = InMemoryPipelineStore()
        let reply = PT.inboundReply(body: "Yes!")
        let ctx = PT.context(thread: [reply], pipeline: pipeline)

        let actions = try await agent(intent: "accept").proposals(for: reply, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(actions.isEmpty)
        #expect(try pipeline.all().isEmpty)   // never classifies / writes without a tracked deal
    }
}
