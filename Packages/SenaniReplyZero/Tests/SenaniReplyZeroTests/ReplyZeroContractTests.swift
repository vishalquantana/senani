import Foundation
import SenaniRules
import SenaniStore
import Testing
@testable import SenaniReplyZero

@Suite struct ReplyZeroContractTests {
    @Test func classifierUsesStructuredSignals() {
        let classifier = NeedsReplyClassifier()
        #expect(classifier.classify(thread: [Self.message(body: "Could you send the deck?")], accountEmail: Self.account) == true)
        #expect(classifier.classify(thread: [Self.message(to: ["other@example.com"])], accountEmail: Self.account) == false)
        #expect(classifier.classify(thread: [Self.message(isFromUser: true)], accountEmail: Self.account) == false)
        #expect(classifier.classify(thread: [Self.message(body: "FYI only.")], accountEmail: Self.account) == false)
    }

    @Test func confirmerCanVetoStructuredPositive() async {
        let classifier = NeedsReplyClassifier()
        let veto = FakePredicateEvaluator(verdict: false)
        let yes = await classifier.classify(
            thread: [Self.message(body: "Can you confirm?")],
            accountEmail: Self.account,
            confirmer: veto
        )
        #expect(yes == false)
        #expect(await veto.calls == 1)
    }

    @Test func storeFlagsClearsAndCounts() throws {
        let store = NeedsReplyStore(database: try SenaniDatabase.inMemory(), now: { 123 })
        try store.set(threadId: "t1", messageId: "m1")
        #expect(try store.pending() == [NeedsReplyFlag(threadId: "t1", messageId: "m1", flaggedAt: 123)])
        #expect(try store.count() == 1)
        try store.clear(threadId: "t1")
        #expect(try store.pending().isEmpty)
    }

    @Test func serviceScansThreads() async throws {
        let store = NeedsReplyStore(database: try SenaniDatabase.inMemory(), now: { 10 })
        let service = ReplyZeroService(store: store, accountEmail: Self.account)
        try await service.scan(threads: [
            "t1": [Self.message(id: "m1", body: "Could you send this?")],
            "t2": [Self.message(id: "m2", body: "No action needed.")],
        ])
        #expect(try service.count() == 1)
        #expect(try service.needsYou().map { $0.threadId } == ["t1"])
    }

    @Test func ruleFactoryProducesEditableBuiltinRule() {
        let rule = replyZeroRule()
        #expect(rule.id == "builtin.reply-zero")
        #expect(rule.actions == [.flagNeedsReply])
        #expect(rule.autonomy == .auto)
        #expect(rule.runOn == .incoming)
        #expect(rule.conditions.aiPredicate != nil)
    }

    static let account = "me@example.com"

    static func message(
        id: String = "m",
        to: [String] = [account],
        body: String = "Could you send it?",
        isFromUser: Bool = false
    ) -> Message {
        Message(
            id: id,
            from: isFromUser ? account : "sender@example.com",
            to: to,
            subject: "Subject",
            body: body,
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: [],
            threadId: "t1",
            date: Date(timeIntervalSince1970: 10),
            isFromUser: isFromUser
        )
    }
}

actor FakePredicateEvaluator: PredicateEvaluator {
    private let verdict: Bool
    private(set) var calls = 0

    init(verdict: Bool) {
        self.verdict = verdict
    }

    func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        calls += 1
        return predicates.map { _ in verdict }
    }
}
