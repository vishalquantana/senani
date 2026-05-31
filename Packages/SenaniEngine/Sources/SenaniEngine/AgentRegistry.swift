import Foundation
import SenaniRules
import SenaniStore

/// Maps a triaged category label → the agents subscribed to it.
///
/// Routing is by the agent's declared `categories` set (Finding 9). The previous implementation
/// probed each agent with a synthetic `__probe__` message and an empty context; agents whose
/// `wakesFor` needs real context (ProposalTracker, FollowUp, Outreach, …) silently never subscribed.
/// Declaring categories statically removes that hidden coupling — an agent subscribes to its
/// category regardless of what its `wakesFor` predicate needs to fire on the real message.
public struct AgentRegistry: Sendable {
    private let agents: [any Agent]

    public init(agents: [any Agent]) {
        self.agents = agents
    }

    public func agents(for category: String) -> [any Agent] {
        guard !category.isEmpty else { return [] }
        return agents.filter { $0.categories.contains(category) }
    }
}
