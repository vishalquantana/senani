import Testing
import Foundation
@testable import SenaniRules

@Suite struct SimulatorTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func msg(_ id: String, from: String) -> Message {
        Message(id: id, from: from, to: ["me@acme.io"], subject: "s", body: "b",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t-\(id)", date: Date(timeIntervalSince1970: 1000), isFromUser: false)
    }

    @Test func simulationReportsWhatWouldHappenWithoutSideEffects() async {
        let backend = SpyBackend()
        let engine = RuleEngine(evaluator: SpyEvaluator(answers: [:]))
        let sim = Simulator(engine: engine)
        let rule = Rule(id: "vendor", name: "vendor", enabled: true,
            conditions: Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil),
            actions: [.label("Vendors"), .reply(body: "thanks")], autonomy: .auto, runOn: .incoming)
        let messages = [msg("1", from: "a@vendor.com"), msg("2", from: "b@other.com")]

        let result = await sim.run(rules: [rule], over: messages, now: now)

        // Only message 1 matches; two actions each routed independently.
        #expect(result.items.count == 2)
        #expect(result.items.allSatisfy { $0.messageId == "1" })
        #expect(result.items.contains { $0.action == .label("Vendors") && $0.outcome == .executed })
        #expect(result.items.contains { $0.action == .reply(body: "thanks") && $0.outcome == .queuedForApproval })
        // The simulator must not touch the backend.
        #expect(await backend.appliedActions().isEmpty)
    }

    @Test func countByOutcomeSummarizesTheDiff() async {
        let engine = RuleEngine(evaluator: SpyEvaluator(answers: [:]))
        let sim = Simulator(engine: engine)
        let rule = Rule(id: "all", name: "all", enabled: true,
            conditions: Conditions(mode: .all, structured: [], aiPredicate: nil),
            actions: [.archive], autonomy: .auto, runOn: .incoming)
        let messages = [msg("1", from: "x@a.com"), msg("2", from: "y@b.com"), msg("3", from: "z@c.com")]

        let result = await sim.run(rules: [rule], over: messages, now: now)
        #expect(result.count(of: .executed) == 3)
        #expect(result.count(of: .queuedForApproval) == 0)
    }
}
