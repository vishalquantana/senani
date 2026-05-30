import Testing
import Foundation
@testable import SenaniRules

/// Records every batch call and returns scripted answers keyed by predicate text.
actor SpyEvaluator: PredicateEvaluator {
    let answers: [String: Bool]
    private(set) var calls: [[String]] = []
    init(answers: [String: Bool]) { self.answers = answers }
    func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        calls.append(predicates)
        return predicates.map { answers[$0] ?? false }
    }
    func recordedCalls() -> [[String]] { calls }
}

@Suite struct RuleEngineTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func msg(from: String = "bob@vendor.com", attach: Bool = true) -> Message {
        Message(id: "m", from: from, to: ["me@acme.io"], subject: "Invoice",
                body: "due", hasAttachment: attach, listUnsubscribeHeader: nil,
                labels: [], threadId: "t1", date: Date(timeIntervalSince1970: 1000),
                isFromUser: false)
    }
    private func rule(_ id: String, _ c: Conditions, enabled: Bool = true) -> Rule {
        Rule(id: id, name: id, enabled: enabled, conditions: c,
             actions: [.label(id)], autonomy: .auto, runOn: .incoming)
    }

    @Test func purelyStructuralMatchNeedsNoModelCall() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil))
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.map(\.rule.id) == ["a"])
        #expect(await spy.recordedCalls().isEmpty) // model never called
    }

    @Test func disabledRulesAreSkipped() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil), enabled: false)
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.isEmpty)
    }

    @Test func predicateOnlyEvaluatedWhenStructuralPasses() async {
        let spy = SpyEvaluator(answers: ["is about pricing": true])
        let engine = RuleEngine(evaluator: spy)
        // r1 structural FAILS -> its predicate must NOT be evaluated.
        let r1 = rule("fails", Conditions(mode: .all, structured: [.domain("other.com")], aiPredicate: "skip me"))
        // r2 structural PASSES and has a predicate -> evaluated.
        let r2 = rule("ai", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r1, r2], now: now)
        #expect(matches.map(\.rule.id) == ["ai"])
        #expect(await spy.recordedCalls().count == 1)                 // exactly one batched call
        #expect(await spy.recordedCalls().first == ["is about pricing"]) // failed rule's predicate excluded
    }

    @Test func predicateFalseRejectsRuleEvenIfStructuralPasses() async {
        let spy = SpyEvaluator(answers: ["is about pricing": false])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("ai", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.isEmpty)
    }

    @Test func noModelCallWhenNoStructuralMatchHasPredicate() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.hasAttachment], aiPredicate: nil))
        _ = await engine.match(message: msg(attach: false), rules: [r], now: now)
        #expect(await spy.recordedCalls().isEmpty)
    }

    @Test func identicalPredicateFromTwoRulesIsDedupedAndBothMatch() async {
        let spy = SpyEvaluator(answers: ["is about pricing": true])
        let engine = RuleEngine(evaluator: spy)
        let r1 = rule("one", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let r2 = rule("two", Conditions(mode: .all, structured: [.hasAttachment], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r1, r2], now: now)
        #expect(matches.map(\.rule.id) == ["one", "two"])     // both rules match
        #expect(await spy.recordedCalls().count == 1)         // single batched call
        #expect(await spy.recordedCalls().first == ["is about pricing"]) // deduped to one entry
    }

    @Test func identicalPredicateFalseRejectsBothRules() async {
        let spy = SpyEvaluator(answers: ["is about pricing": false])
        let engine = RuleEngine(evaluator: spy)
        let r1 = rule("one", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let r2 = rule("two", Conditions(mode: .all, structured: [.hasAttachment], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r1, r2], now: now)
        #expect(matches.isEmpty) // both rejected
    }
}
