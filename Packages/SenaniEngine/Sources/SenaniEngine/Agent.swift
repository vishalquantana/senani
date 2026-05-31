import Foundation
import SenaniRules
import SenaniStore

public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    public let needsReply: Bool
    public let documentFields: [String: String]
    public let pipeline: any PipelineStore
    /// ⚠ CONTRACT ADDITION (Finance plan): the store for captured invoices.
    public let invoices: any InvoiceStore

    public init(account: String,
                thread: [Message],
                rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date,
                needsReply: Bool = false,
                documentFields: [String: String] = [:],
                pipeline: any PipelineStore,
                invoices: any InvoiceStore = NullInvoiceStore()) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.needsReply = needsReply
        self.documentFields = documentFields
        self.pipeline = pipeline
        self.invoices = invoices
    }
}

public protocol Agent: Sendable {
    var id: String { get }
    var autonomy: Autonomy { get }
    /// The triage categories (labels) this agent subscribes to. The Orchestrator routes a triaged
    /// message to an agent iff its category label is in this set. Defaults to empty so list-driven /
    /// signal-gated agents (Outreach, ReplyDrafter, etc.) that are not category-routed still compile
    /// without declaring anything.
    var categories: Set<String> { get }
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

extension Agent {
    public var categories: Set<String> { [] }
}
