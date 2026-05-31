import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

// A scripted sync seam: returns a fixed batch and records the query it was asked.
actor FakeGmailSync: GmailSyncing {
    private var batches: [[Message]]
    private(set) var queries: [String] = []
    private(set) var callCount = 0
    init(batches: [[Message]]) { self.batches = batches }
    init(batch: [Message]) { self.batches = [batch] }
    func fetchMessages(query: String, maxResults: Int) async throws -> [Message] {
        callCount += 1
        queries.append(query)
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}

@Test func fakeGmailSyncConformsToTheSeam() async throws {
    let sync: any GmailSyncing = FakeGmailSync(batch: [msg("m1")])
    let out = try await sync.fetchMessages(query: "newer_than:7d", maxResults: 50)
    #expect(out.map(\.id) == ["m1"])
}

import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func leadOrchestrator(_ h: EngineHarness) -> Orchestrator {
    let labeler = FakeAgent(id: "labeler", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("SEEN", on: msg("x"))] })
    return Orchestrator(registry: AgentRegistry(agents: [labeler]),
                        triage: triageTagging("Lead"),
                        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                        messages: h.messages, index: h.index, embedder: h.embedder,
                        generator: h.generator,
                        pipeline: h.pipeline,
                        rules: h.rules, now: h.now)
}

@Test func tickSyncsSavesAndProcesses() async throws {
    let h = try EngineHarness()
    let sync = FakeGmailSync(batch: [msg("g1", labels: ["Lead"], threadId: "tg1"),
                                     msg("g2", labels: ["Lead"], threadId: "tg2")])
    let orch = leadOrchestrator(h)
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 60, now: h.now)

    try await scheduler.tick()

    let saved = Set(try h.messages.all().map(\.id))
    #expect(saved == ["g1", "g2"])
    let applied = await h.backend.applied
    let seen = Set(applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seen == ["g1", "g2"])
    #expect(await sync.callCount == 1)
}

@Test func tickWithEmptySyncProcessesExistingInbox() async throws {
    let h = try EngineHarness()
    try h.messages.save(msg("existing", labels: ["Lead"], threadId: "te"))
    let sync = FakeGmailSync(batch: [])
    let orch = leadOrchestrator(h)
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 60, now: h.now)

    try await scheduler.tick()

    let applied = await h.backend.applied
    let seen = Set(applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seen == ["existing"])
}

@Test func startRespectsLowPowerBySkippingTheCycle() async throws {
    let h = try EngineHarness()
    let sync = FakeGmailSync(batches: [[msg("g1", labels: ["Lead"])], [msg("g2", labels: ["Lead"])]])
    let orch = leadOrchestrator(h)
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 0.01, now: h.now, isLowPower: { true })

    await scheduler.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await scheduler.stop()

    #expect(await sync.callCount == 0)
    let applied = await h.backend.applied
    #expect(applied.isEmpty)
}
