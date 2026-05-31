import Testing
import Foundation
@testable import SenaniApp
import SenaniEngine
import SenaniRules

/// A thread-safe recorder for assertions made from @Sendable closures.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ value: Value) { lock.lock(); _value = value; lock.unlock() }
}

private func outreachTarget(_ contact: String, company: String? = "Acme", daysAgo: Double = 30) -> OutreachTarget {
    OutreachTarget(
        contactEmail: contact,
        deal: Deal(id: contact, contactEmail: contact, company: company, stage: .qualified,
                   score: 70, value: nil,
                   lastTouch: Date().addingTimeInterval(-daysAgo * 86_400), sourceMessageId: nil),
        thread: [])
}

@MainActor
@Suite struct OutreachViewModelTests {
    @Test func refreshListsDormantTargets() async {
        let vm = OutreachViewModel(
            dormantTargets: { [outreachTarget("a@x.com"), outreachTarget("b@x.com", company: nil)] },
            runOutreach: { _ in [] })
        vm.refresh()
        #expect(vm.rows.map(\.id) == ["a@x.com", "b@x.com"])
        #expect(vm.rows.allSatisfy { !$0.isSelected })
        #expect(vm.selectedCount == 0)
    }

    @Test func toggleSelectsRowsAndDraftRunsOnlySelected() async {
        let received = Recorder<[OutreachTarget]>([])
        let vm = OutreachViewModel(
            dormantTargets: { [outreachTarget("a@x.com"), outreachTarget("b@x.com")] },
            runOutreach: { targets in
                received.set(targets)
                return targets.map { _ in ProcessedOutcome(agentId: "outreach", action: .send(body: "x"), outcome: .queuedForApproval) }
            })
        vm.refresh()
        vm.toggle(id: "a@x.com")
        #expect(vm.selectedCount == 1)

        await vm.draftSelected()
        #expect(received.value.map(\.contactEmail) == ["a@x.com"])
        #expect(vm.lastQueuedCount == 1)
        #expect(vm.lastError == nil)
    }

    @Test func draftWithNoSelectionIsANoOp() async {
        let called = Recorder<Bool>(false)
        let vm = OutreachViewModel(
            dormantTargets: { [outreachTarget("a@x.com")] },
            runOutreach: { _ in called.set(true); return [] })
        vm.refresh()
        await vm.draftSelected()
        #expect(called.value == false)
        #expect(vm.lastQueuedCount == nil)
    }

    @Test func draftErrorIsSurfaced() async {
        struct Boom: Error {}
        let vm = OutreachViewModel(
            dormantTargets: { [outreachTarget("a@x.com")] },
            runOutreach: { _ in throw Boom() })
        vm.refresh()
        vm.toggle(id: "a@x.com")
        await vm.draftSelected()
        #expect(vm.lastError != nil)
        #expect(vm.lastQueuedCount == nil)
    }

    // Safety: through the live AppEnvironment graph, drafting outreach NEVER applies to the mail
    // backend — drafts only land in the approval queue.
    @Test func liveDraftQueuesForApprovalAndNeverHitsTheBackend() async throws {
        let env = AppEnvironment.preview()
        // Seed a dormant open deal so a target exists.
        try env.pipeline.upsert(
            Deal(id: "dormant@x.com", contactEmail: "dormant@x.com", company: "Globex",
                 stage: .negotiation, score: 60, value: nil,
                 lastTouch: Date().addingTimeInterval(-45 * 86_400), sourceMessageId: nil))

        let vm = OutreachViewModel(environment: env)
        vm.refresh()
        #expect(vm.rows.contains { $0.id == "dormant@x.com" })
        vm.toggle(id: "dormant@x.com")

        await vm.draftSelected()

        #expect(vm.lastError == nil)
        #expect((vm.lastQueuedCount ?? 0) >= 1)
        // SAFETY INVARIANT: the spy mail backend was never called — nothing was sent.
        #expect(env.spyBackend.applied.isEmpty)
        // The draft is waiting in the approval queue.
        #expect(try env.approvals.pending().contains { $0.proposal.message.to == ["dormant@x.com"] })
    }
}
