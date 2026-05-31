import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

// A spy MailBackend recording every applied (action, messageId).
private final class LocalSpyMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(Action, String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        _record(action, message.id)
    }
    private func _record(_ action: Action, _ id: String) {
        lock.lock(); _applied.append((action, id)); lock.unlock()
    }
    var applied: [(Action, String)] {
        lock.lock(); defer { lock.unlock() }; return _applied
    }
}

private func msg(_ id: String) -> Message {
    Message(id: id, from: "a@b.com", to: ["me@x.com"], subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(), isFromUser: false)
}

/// Builds a VM over an in-memory ApprovalStore seeded with two proposals.
@MainActor
private func seededVM(backend: LocalSpyMailBackend) throws -> (ApprovalQueueViewModel, ApprovalStore) {
    let db = try SenaniDatabase.inMemory()
    let clock = IncrementingClock()
    let store = ApprovalStore(database: db, now: { clock.next() })
    try store.enqueue(id: "ap-reply",
        Proposal(action: .reply(body: "Our Pro tier is $199/yr."), message: msg("m1"), trigger: .rule(id: "reply-drafter")))
    try store.enqueue(id: "ap-label",
        Proposal(action: .label("Invoices"), message: msg("m2"), trigger: .rule(id: "triage")))
    let vm = ApprovalQueueViewModel(
        pending: { try store.pending() },
        approve: { try store.approve(id: $0) },
        reject: { try store.reject(id: $0) },
        apply: { try await backend.apply($0, to: $1) })
    return (vm, store)
}

private final class IncrementingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

@MainActor
@Test func refreshLoadsPendingCards() throws {
    let backend = LocalSpyMailBackend()
    let (vm, _) = try seededVM(backend: backend)
    vm.refresh()
    #expect(vm.cards.count == 2)
    // Order from store (ap-label vs ap-reply id sort if timestamps tie)
    #expect(Set(vm.cards.map(\.id)) == ["ap-reply", "ap-label"])
}

@MainActor
@Test func approveCallsApproveThenAppliesThenRefreshes() async throws {
    let backend = LocalSpyMailBackend()
    let (vm, store) = try seededVM(backend: backend)
    vm.refresh()
    await vm.approve(id: "ap-reply")
    // Executed via the backend.
    #expect(backend.applied.count == 1)
    #expect(backend.applied.first?.1 == "m1")
    if case .reply = backend.applied.first?.0 {} else { Issue.record("expected a reply action") }
    // Approved row no longer pending.
    #expect(try store.pending().map(\.id) == ["ap-label"])
    #expect(vm.cards.map(\.id) == ["ap-label"])
    #expect(vm.lastError == nil)
}

@MainActor
@Test func rejectCallsRejectAndDoesNotApply() async throws {
    let backend = LocalSpyMailBackend()
    let (vm, store) = try seededVM(backend: backend)
    vm.refresh()
    await vm.reject(id: "ap-reply")
    #expect(backend.applied.isEmpty)                       // NEVER executed
    #expect(try store.pending().map(\.id) == ["ap-label"]) // rejected row gone from pending
    #expect(vm.cards.map(\.id) == ["ap-label"])
}

@MainActor
@Test func approvingAReversibleLabelAlsoApplies() async throws {
    let backend = LocalSpyMailBackend()
    let (vm, _) = try seededVM(backend: backend)
    vm.refresh()
    await vm.approve(id: "ap-label")
    #expect(backend.applied.count == 1)
    if case .label("Invoices") = backend.applied.first?.0 {} else { Issue.record("expected label action") }
}

@MainActor
@Test func applyFailureIsCapturedAndListStillRefreshes() async throws {
    struct FailingBackend: MailBackend {
        func apply(_ action: Action, to message: Message) async throws { throw CancellationError() }
    }
    let db = try SenaniDatabase.inMemory()
    let store = ApprovalStore(database: db, now: { 0 })
    try store.enqueue(id: "ap-x", Proposal(action: .reply(body: "hi"), message: msg("m1"), trigger: .rule(id: "reply-drafter")))
    let vm = ApprovalQueueViewModel(
        pending: { try store.pending() },
        approve: { try store.approve(id: $0) },
        reject: { try store.reject(id: $0) },
        apply: { try await FailingBackend().apply($0, to: $1) })
    vm.refresh()
    await vm.approve(id: "ap-x")
    #expect(vm.lastError != nil)                           // surfaced
    #expect(try store.pending().isEmpty)                   // still approved (removed from pending)
    #expect(vm.cards.isEmpty)
}

@MainActor
@Test func approvalInitFromPreviewEnvironmentBuilds() {
    let env = AppEnvironment.preview()
    let vm = ApprovalQueueViewModel(environment: env)
    vm.refresh()
    #expect(vm.cards.isEmpty)   // preview seeds nothing here; the preview-graph test seeds explicitly
}

@MainActor
@Test func approveExecutesThroughThePreviewSpyBackend() async throws {
    let env = AppEnvironment.preview()
    // Seed a pending outbound proposal directly into the preview ApprovalStore.
    try env.approvals.enqueue(id: "ap-seed",
        Proposal(action: .reply(body: "Thanks for reaching out!"),
                 message: msg("seed-1"), trigger: .rule(id: "reply-drafter")))
    let vm = ApprovalQueueViewModel(environment: env)
    vm.refresh()
    #expect(vm.cards.map(\.id) == ["ap-seed"])
    await vm.approve(id: "ap-seed")
    // The preview spy backend recorded the apply.
    let appliedIds = env.spyBackend.applied.map { $0.message.id }
    #expect(appliedIds == ["seed-1"])
    #expect(try env.approvals.pending().isEmpty)
    #expect(vm.cards.isEmpty)
}
