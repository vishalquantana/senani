import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func makeOrchestrator(_ h: EngineHarness, triage: any Agent, agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents), triage: triage,
                 mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                 messages: h.messages, index: h.index, embedder: h.embedder,
                 generator: h.generator, pipeline: h.pipeline, rules: h.rules, now: h.now)
}

@Test func everyOutcomeIsAuditedWithTheAgentsTrigger() async throws {
    let h = try EngineHarness()
    let message = msg("m1", labels: ["Lead"])
    try h.messages.save(message)

    let drafter = FakeAgent(id: "reply-drafter", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { m, _, tools in [tools.draftReply(to: m, body: "Hi")] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [drafter])

    _ = try await orch.process(message)

    let entries = try await h.audit.records()
    // One record for triage's .label("Lead"), one for the drafter's .draft.
    let triageRecords = entries.filter { $0.record.trigger == .rule(id: "triage") }
    let drafterRecords = entries.filter { $0.record.trigger == .rule(id: "reply-drafter") }
    #expect(triageRecords.count == 1)
    #expect(triageRecords.first?.record.action == .label("Lead"))
    #expect(triageRecords.first?.record.outcome == .executed)        // reversible + auto
    #expect(drafterRecords.count == 1)
    #expect(drafterRecords.first?.record.action == .reply(body: "Hi"))
    #expect(drafterRecords.first?.record.outcome == .queuedForApproval) // outbound always queues
    #expect(entries.allSatisfy { $0.record.messageId == "m1" })
}

@Test func outboundOutcomeIsAuditedAsQueued() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let sender = FakeAgent(id: "sender", autonomy: .auto,
                           wakes: { m, _ in m.labels.contains("Lead") },
                           emit: { _, _, _ in [.send(body: "Now")] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [sender])

    _ = try await orch.process(message)

    let entries = try await h.audit.records()
    let sendRecord = entries.first { $0.record.trigger == .rule(id: "sender") }
    #expect(sendRecord?.record.outcome == .queuedForApproval)        // outbound always queues
    #expect(sendRecord?.record.action == .send(body: "Now"))
}

@Test func processInboxCoversEveryStoredMessage() async throws {
    let h = try EngineHarness()
    try h.messages.saveAll([
        msg("a", labels: ["Lead"], threadId: "ta"),
        msg("b", labels: ["Lead"], threadId: "tb"),
        msg("c", labels: ["Lead"], threadId: "tc"),
    ])

    // Triage tags Lead; one subscriber labels each message so we can count coverage.
    let labeler = FakeAgent(id: "labeler", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("SEEN", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [labeler])

    let outcomes = try await orch.processInbox()

    let applied = await h.backend.applied
    let seenMessageIds = Set(applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seenMessageIds == ["a", "b", "c"])
    // 3 messages * (triage label + labeler label) = 6 routed outcomes.
    #expect(outcomes.count == 6)
}
