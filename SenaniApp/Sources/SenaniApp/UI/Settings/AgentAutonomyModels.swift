import SenaniRules

/// One agent's autonomy row in Settings. Equatable for direct test assertions.
public struct AgentAutonomy: Sendable, Equatable, Identifiable {
    public let agentId: String
    public let displayName: String
    public let autonomy: Autonomy
    public var id: String { agentId }

    public init(agentId: String, displayName: String, autonomy: Autonomy) {
        self.agentId = agentId
        self.displayName = displayName
        self.autonomy = autonomy
    }
}
