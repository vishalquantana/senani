import SenaniRules

public struct ProcessedOutcome: Sendable, Equatable {
    public let agentId: String
    public let action: Action
    public let outcome: Outcome
    public init(agentId: String, action: Action, outcome: Outcome) {
        self.agentId = agentId
        self.action = action
        self.outcome = outcome
    }
}
