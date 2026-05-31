import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ProposalTrackerWakesForTests {
    private func agent() -> ProposalTrackerAgent {
        ProposalTrackerAgent(classifier: ReplyIntentClassifier(generator: FakeTextGenerator(response: #"{"intent":"other"}"#)))
    }

    @Test func wakesForOutboundProposalWithDocValue() {
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: InMemoryPipelineStore(),
                             documentFields: ["total": "12000"])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForOutboundProposalViaSubjectCue() {
        let m = PT.outboundProposal(subject: "Quotation enclosed", hasAttachment: false)
        let ctx = PT.context(thread: [m], pipeline: InMemoryPipelineStore())
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForInboundReplyOnTrackedThread() {
        let reply = PT.inboundReply(body: "Sounds good!")
        let pipeline = InMemoryPipelineStore()
        try? pipeline.upsert(PT.dealAt(.proposal))
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)
        #expect(agent().wakesFor(reply, context: ctx) == true)
    }

    @Test func doesNotWakeForInboundReplyOnUntrackedThread() {
        let reply = PT.inboundReply(body: "Sounds good!")
        let ctx = PT.context(thread: [reply], pipeline: InMemoryPipelineStore())  // no deal
        #expect(agent().wakesFor(reply, context: ctx) == false)
    }

    @Test func doesNotWakeForOrdinaryOutboundMail() {
        let ctx = PT.context(thread: [PT.ordinaryOutbound()], pipeline: InMemoryPipelineStore())
        #expect(agent().wakesFor(PT.ordinaryOutbound(), context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "proposal-tracker")
        #expect(a.autonomy == .prepare)
    }
}
