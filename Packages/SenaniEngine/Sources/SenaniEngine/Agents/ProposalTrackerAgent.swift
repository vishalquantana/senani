import Foundation
import SenaniRules

/// Phase-3 Proposal Tracker. Keeps the CRM pipeline in step with proposal/quote email.
public struct ProposalTrackerAgent: Agent {
    public let id = "proposal-tracker"
    public let autonomy: Autonomy = .prepare

    /// Category routing (Finding 9): tracks outbound proposals AND inbound replies on tracked deals —
    /// not bound to one category, so it subscribes to all and `wakesFor` gates firing.
    public var categories: Set<String> { TriageCategory.allLabels }

    private let detector: ProposalDetector
    private let classifier: ReplyIntentClassifier

    public init(detector: ProposalDetector = ProposalDetector(), classifier: ReplyIntentClassifier) {
        self.detector = detector
        self.classifier = classifier
    }

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser {
            return detector.detect(message, documentFields: context.documentFields) != nil
        } else {
            return (try? context.pipeline.byContact(message.from)) != nil
        }
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        if message.isFromUser {
            return try handleOutboundProposal(message, context: context)
        } else {
            return try await handleInboundReply(message, context: context, tools: tools)
        }
    }

    private func handleOutboundProposal(_ message: Message, context: AgentContext) throws -> [Action] {
        guard let signal = detector.detect(message, documentFields: context.documentFields) else {
            return []
        }
        let contact = message.to.first ?? ""
        guard !contact.isEmpty else { return [] }

        let existing = try context.pipeline.byContact(contact)
        let deal = Deal(
            id: existing?.id ?? contact,
            contactEmail: contact,
            company: existing?.company,
            stage: .proposal,
            score: existing?.score,
            value: signal.value ?? existing?.value,
            lastTouch: message.date,
            sourceMessageId: message.id,
            threadId: existing?.threadId ?? message.threadId
        )
        try context.pipeline.upsert(deal)
        return []
    }

    private func handleInboundReply(_ message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard let existing = try context.pipeline.byContact(message.from) else {
            return []
        }
        let stage = try await classifier.classify(reply: message)
        let updated = Deal(
            id: existing.id,
            contactEmail: existing.contactEmail,
            company: existing.company,
            stage: stage,
            score: existing.score,
            value: existing.value,
            lastTouch: message.date,
            sourceMessageId: message.id,
            threadId: existing.threadId
        )
        try context.pipeline.upsert(updated)

        switch stage {
        case .won:
            return [tools.draftReply(to: message,
                body: "Thank you — delighted to move forward. I'll send next steps shortly.")]
        case .negotiation:
            return [tools.draftReply(to: message,
                body: "Thanks for the note — happy to discuss. When works for a quick call?")]
        default:
            return []
        }
    }
}
