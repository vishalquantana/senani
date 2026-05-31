import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

// The linchpin the audit said was missing: drive the REAL TriageAgent through the Orchestrator into
// a REAL subscriber agent (BookingAgent) end-to-end, with no FakeAgent stand-ins for either side.
//
// Exercises Findings 2 (in-cycle label folding), 3 (canonical Booking label), and 9 (category
// routing) together: triage assigns "Senani/Category/Booking", which is folded into the in-memory
// message and routed — within ONE process() call — to BookingAgent, whose outbound reply queues.

@Suite struct OrchestratorEndToEndTests {

    private func makeOrchestrator(_ h: EngineHarness, booking: BookingAgent) -> Orchestrator {
        Orchestrator(
            registry: AgentRegistry(agents: [booking]),
            triage: TriageAgent(),
            mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
            messages: h.messages, index: h.index, embedder: h.embedder,
            generator: h.generator, pipeline: h.pipeline, rules: h.rules,
            now: { BK.now })
    }

    @Test func realTriageRoutesToRealBookingAgentInOneCycle() async throws {
        let h = try EngineHarness()
        // Real triage classifies this as Booking.
        await h.generator.preload(#"{"category":"Booking","priority":"high","reason":"meeting request"}"#)

        let incoming = Message(
            id: "e2e-1", from: "sarah@client.com", to: [BK.account],
            subject: "Can we meet next week?", body: "Hi, do you have 30 minutes to discuss?",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],   // UNLABELED on arrival
            threadId: "te2e", date: BK.now, isFromUser: false)
        try h.messages.save(incoming)

        let booking = BookingAgent(
            availability: FakeAvailabilityProvider(busy: BK.cannedBusy()),
            generator: nil, timeZone: BK.utc)
        let orch = makeOrchestrator(h, booking: booking)

        let outcomes = try await orch.process(incoming)

        // Triage emitted + applied the canonical Booking category label (reversible, .auto -> executed).
        let applied = await h.backend.applied
        #expect(applied.contains { $0.action == .label(TriageCategory.booking.label) && $0.messageId == "e2e-1" })

        // BookingAgent woke (because the label was folded in mid-cycle) and produced an OUTBOUND reply
        // that ALWAYS queues — never auto-sent.
        let bookingOutcome = outcomes.first { $0.agentId == "booking" }
        #expect(bookingOutcome != nil)
        #expect(bookingOutcome?.outcome == .queuedForApproval)
        if case .reply = bookingOutcome?.action { } else { Issue.record("expected an outbound reply action") }

        // The reply is in the approval queue (safety invariant: outbound queues), not applied to the backend.
        #expect(applied.contains { if case .reply = $0.action { return true } else { return false } } == false)
        let pending = try h.approvals.pending()
        #expect(pending.contains { if case .reply = $0.proposal.action { return true } else { return false } })
    }
}
