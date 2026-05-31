import Foundation
import SenaniRules

/// Phase-2 Inbox Hygiene agent. Wakes for bulk/newsletter mail and proposes:
///   1. REVERSIBLE declutter Actions — `proposeLabel("Senani/Newsletter")`, `markRead`, `archive` —
///      which auto-apply per the agent's autonomy dial (the Orchestrator routes them).
///   2. An approval-gated UNSUBSCRIBE: if the `List-Unsubscribe` header carries a `mailto:` target,
///      ONE outbound `Action.reply(body:)` (`actionClass == .outbound`) so `ActionRouter` ALWAYS
///      queues it. It is NEVER auto-sent. The HTTPS one-click POST form is NOT actioned (no Action
///      case exists — a §5 escalation); its target is surfaced on the `HygieneFinding` instead.
///
/// The agent is model-free: every decision is deterministic from the header, the Triage Newsletter
/// label, and a repeat-sender frequency heuristic over the thread. Pure → trivially unit-testable.
public struct InboxHygieneAgent: Agent {
    public let id = "inbox-hygiene"
    /// `.prepare`: declutter is staged for one-click (or auto under `.auto`); the unsubscribe reply
    /// is outbound so it queues regardless of this dial.
    public let autonomy: Autonomy = .prepare

    /// The Triage agent's Newsletter category label (see Triage plan).
    public static let newsletterCategoryLabel = "Senani/Category/Newsletter"

    /// Category routing (Finding 9): bulk mail (List-Unsubscribe / repeat-sender) can be triaged under
    /// any category, not just Newsletter, so it subscribes to all and `wakesFor` gates firing.
    public var categories: Set<String> { TriageCategory.allLabels }
    /// The hygiene label this agent applies.
    public static let hygieneLabel = "Senani/Newsletter"
    /// How many messages from the same domain in the thread count as a "repeat sender".
    public static let repeatSenderThreshold = 2

    public init() {}

    // MARK: - Trigger

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard !message.isFromUser else { return false }
        // Strongest signal: a List-Unsubscribe header means it is bulk mail.
        if let header = message.listUnsubscribeHeader, ListUnsubscribeParser.parse(header).hasAny {
            return true
        }
        // Otherwise: Triage tagged it Newsletter AND the sender recurs in the thread.
        if message.labels.contains(Self.newsletterCategoryLabel),
           Self.senderFrequency(of: message, in: context.thread) >= Self.repeatSenderThreshold {
            return true
        }
        return false
    }

    // MARK: - Proposals

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        // 1. Reversible declutter set (auto-applies per autonomy dial).
        var actions: [Action] = [
            tools.proposeLabel(Self.hygieneLabel, on: message),
            tools.markRead(message),
            tools.archive(message),
        ]

        // 2. Approval-gated unsubscribe (mailto form only). Outbound → always queues.
        let parsed = parsedHeader(for: message)
        if parsed.mailto != nil {
            actions.append(tools.reply(to: message, body: Self.unsubscribeBody))
        }
        // The https one-click form is intentionally NOT actioned here (§5 escalation); the target is
        // available via `finding(for:context:)` for the UI / a future capability.

        return actions
    }

    // MARK: - Finding (structured view the Orchestrator/UI can surface)

    /// A structured summary of what the agent saw — including the parsed unsubscribe targets and
    /// the explicit flag that one-click HTTPS unsubscribe is not yet a supported capability.
    public struct HygieneFinding: Sendable, Equatable {
        public let messageId: String
        public let isBulk: Bool
        public let mailtoUnsubscribe: String?
        public let httpsUnsubscribe: String?
        /// True when an HTTPS one-click target exists but no `Action`/tool can act on it (§5).
        public let oneClickUnsupported: Bool
    }

    public func finding(for message: Message, context: AgentContext) -> HygieneFinding {
        let parsed = parsedHeader(for: message)
        return HygieneFinding(
            messageId: message.id,
            isBulk: wakesFor(message, context: context),
            mailtoUnsubscribe: parsed.mailto,
            httpsUnsubscribe: parsed.https,
            oneClickUnsupported: parsed.https != nil
        )
    }

    // MARK: - Helpers (pure)

    /// The standardized unsubscribe email body.
    static let unsubscribeBody = "Please unsubscribe me from this mailing list."

    private func parsedHeader(for message: Message) -> ListUnsubscribeParser {
        guard let header = message.listUnsubscribeHeader else {
            return ListUnsubscribeParser(mailto: nil, https: nil)
        }
        return ListUnsubscribeParser.parse(header)
    }

    /// How many messages in `thread` share `message`'s sender domain (including itself).
    static func senderFrequency(of message: Message, in thread: [Message]) -> Int {
        let domain = message.senderDomain
        guard !domain.isEmpty else { return 0 }
        return thread.filter { $0.senderDomain == domain }.count
    }
}
