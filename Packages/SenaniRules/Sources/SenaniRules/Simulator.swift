import Foundation

/// The faithful dry-run: same engine + same routing as live execution, side effects suppressed.
public struct SimulationResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let messageId: String
        public let ruleId: String
        public let action: Action
        public let outcome: Outcome
        public init(messageId: String, ruleId: String, action: Action, outcome: Outcome) {
            self.messageId = messageId
            self.ruleId = ruleId
            self.action = action
            self.outcome = outcome
        }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public func count(of outcome: Outcome) -> Int {
        items.filter { $0.outcome == outcome }.count
    }
}

/// Runs rules against a set of messages and reports what WOULD happen.
public struct Simulator: Sendable {
    private let engine: RuleEngine
    public init(engine: RuleEngine) { self.engine = engine }

    public func run(rules: [Rule], over messages: [Message], now: Date) async -> SimulationResult {
        var items: [SimulationResult.Item] = []
        for message in messages {
            let matches = await engine.match(message: message, rules: rules, now: now)
            for match in matches {
                for action in match.rule.actions {
                    let outcome = ActionRouter.route(action, autonomy: match.rule.autonomy)
                    items.append(.init(
                        messageId: message.id, ruleId: match.rule.id,
                        action: action, outcome: outcome))
                }
            }
        }
        return SimulationResult(items: items)
    }
}
