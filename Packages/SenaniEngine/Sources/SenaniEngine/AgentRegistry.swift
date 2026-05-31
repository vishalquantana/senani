import Foundation
import SenaniRules
import SenaniStore

public struct AgentRegistry: Sendable {
    private let agents: [any Agent]

    public init(agents: [any Agent]) {
        self.agents = agents
    }

    public func agents(for category: String) -> [any Agent] {
        let probe = Self.probeMessage(category: category)
        let context = Self.emptyContext()
        return agents.filter { $0.wakesFor(probe, context: context) }
    }

    private static func probeMessage(category: String) -> Message {
        Message(id: "__probe__", from: "", to: [], subject: "", body: "",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [category],
                threadId: "__probe__", date: Date(timeIntervalSince1970: 0), isFromUser: false)
    }

    private static func emptyContext() -> AgentContext {
        AgentContext(account: "", thread: [], rules: [],
                     retrieve: { _, _ in [] },
                     now: Date(timeIntervalSince1970: 0),
                     pipeline: StaticPipelineStore())
    }
}

private struct StaticPipelineStore: PipelineStore {
    func upsert(_ deal: Deal) throws {}
    func fetch(id: String) throws -> Deal? { nil }
    func byContact(_ email: String) throws -> Deal? { nil }
    func all() throws -> [Deal] { [] }
    func byStage(_ stage: DealStage) throws -> [Deal] { [] }
    func openDeals() throws -> [Deal] { [] }
    func deal(threadId: String) throws -> Deal? { nil }
    func touch(dealId: String, at date: Date) throws {}
}
