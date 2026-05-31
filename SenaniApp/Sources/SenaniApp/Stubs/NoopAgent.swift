import SenaniEngine
import SenaniRules

/// Phase-0 placeholder satisfying the Orchestrator's required `triage` argument
/// before the real Triage agent exists. It wakes for nothing and emits no
/// proposals, so `processInbox()` is a no-op until real agents are registered.
public struct NoopAgent: Agent {
    public init() {}
    public var id: String { "noop" }
    public var autonomy: Autonomy { .ask }
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool { false }
    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] { [] }
}
