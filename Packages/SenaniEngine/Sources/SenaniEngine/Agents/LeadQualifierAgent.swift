import Foundation
import SenaniRules

/// Phase-3 Lead Qualifier (ROADMAP Phase 3). For every inbound message Triage
/// labeled `Senani/Category/Lead`, it scores the lead 0–100 + extracts company/intent
/// via the injected TextGenerator, emits one reversible `Senani/Lead/<Tier>` label,
/// and upserts a qualified Deal into the injected PipelineStore.
/// Pure aside from two injected seams: `tools.generateJSON` and `context.pipeline`.
public struct LeadQualifierAgent: Agent {
    public init() {}

    public var id: String { "lead-qualifier" }

    /// The label proposal is reversible, so the Orchestrator may auto-apply it.
    public var autonomy: Autonomy { .auto }

    /// The Triage category label this agent subscribes to.
    public static let leadCategoryLabel = "Senani/Category/Lead"
    private static let leadTierPrefix = "Senani/Lead/"

    /// Category routing (Finding 9): Lead is category-specific — it subscribes ONLY to Lead-classified mail.
    public var categories: Set<String> { [Self.leadCategoryLabel] }

    /// Wakes ONLY for inbound, Triage-classified Lead messages not yet lead-qualified.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser { return false }
        guard message.labels.contains(Self.leadCategoryLabel) else { return false }
        if message.labels.contains(where: { $0.hasPrefix(Self.leadTierPrefix) }) { return false }
        return true
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        let prompt = Self.buildPrompt(for: message)
        let raw = try await tools.generateJSON(prompt: prompt, schema: LeadQualification.schema)
        let qualification = LeadQualification.parse(raw)

        // Side effect 1: record the Deal in the CRM pipeline (injected seam).
        let deal = Self.makeDeal(for: message, qualification: qualification,
                                 existing: try? context.pipeline.byContact(message.from),
                                 now: context.now)
        try context.pipeline.upsert(deal)

        // Side effect 2 (via the Orchestrator): propose the reversible tier label.
        return [tools.proposeLabel(qualification.tier.label, on: message)]
    }

    /// Builds (or updates) the Deal. Deterministic id = contact email so re-qualifying the
    /// same sender updates the same Deal (upsert). Preserves an existing Deal's id/value.
    static func makeDeal(for message: Message, qualification: LeadQualification,
                         existing: Deal?, now: Date) -> Deal {
        Deal(
            id: existing?.id ?? message.from,
            contactEmail: message.from,
            company: qualification.company ?? existing?.company,
            stage: .qualified,
            score: qualification.score,
            value: existing?.value,            // qualifier does not set deal value
            lastTouch: now,
            sourceMessageId: message.id,
            threadId: existing?.threadId ?? message.threadId
        )
    }

    /// Deterministic prompt: fixed policy/system instruction + the message signals.
    /// Body truncated to a snippet to keep the prompt small for the on-device model.
    static func buildPrompt(for message: Message) -> String {
        let intents = LeadIntent.allCases.map(\.rawValue).joined(separator: ", ")
        let snippet = String(message.body.prefix(800))
        return """
        You are Senani's B2B lead qualifier. Score ONE inbound sales lead.
        Reply with ONLY a JSON object: \
        {"score": <integer 0-100>, "company": <the prospect's company name or "">, \
        "intent": <one of: \(intents)>, "reason": <one short sentence>}.
        Scoring guide: 70-100 = hot (ready to buy, budget/timeline clear), \
        40-69 = warm (evaluating, genuine interest), 0-39 = cold (vague, info-only, or not a real lead).
        Choose exactly one intent from the list. Do not invent fields or values.

        EMAIL
        From: \(message.from)
        Subject: \(message.subject)
        Body: \(snippet)
        """
    }
}
