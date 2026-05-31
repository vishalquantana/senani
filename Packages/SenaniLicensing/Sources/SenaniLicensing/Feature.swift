import Foundation

/// Gateable capabilities. Agent-backed cases carry the SAME stable id as the
/// corresponding `Agent.id` so the composition root can filter the agent list by
/// tier. `pipelineCRM` is a UI surface (Phase 3), not an agent.
public enum Feature: String, Sendable, CaseIterable {
    // Core ($99) — Roadmap Phases 1–2
    case triage
    case replyDrafter
    case booking
    case dailyDigest
    case inboxHygiene
    // Pro ($199) — Roadmap Phase 3 sales suite
    case leadQualifier
    case proposalTracker
    case followUp
    case outreach
    case invoiceFinance
    case pipelineCRM

    /// The minimum tier that unlocks this feature.
    public var minimumTier: LicenseTier {
        switch self {
        case .triage, .replyDrafter, .booking, .dailyDigest, .inboxHygiene:
            return .core
        case .leadQualifier, .proposalTracker, .followUp, .outreach, .invoiceFinance, .pipelineCRM:
            return .pro
        }
    }

    /// Stable `Agent.id` for agent-backed features; nil for non-agent surfaces.
    public var agentID: String? {
        switch self {
        case .triage:           return "triage"
        case .replyDrafter:     return "reply-drafter"
        case .booking:          return "booking"
        case .dailyDigest:      return "daily-digest"
        case .inboxHygiene:     return "inbox-hygiene"
        case .leadQualifier:    return "lead-qualifier"
        case .proposalTracker:  return "proposal-tracker"
        case .followUp:         return "follow-up"
        case .outreach:         return "outreach"
        case .invoiceFinance:   return "invoice-finance"
        case .pipelineCRM:      return nil
        }
    }

    /// Reverse lookup from a stable agent id.
    public init?(agentID: String) {
        guard let match = Feature.allCases.first(where: { $0.agentID == agentID }) else { return nil }
        self = match
    }
}

public extension LicenseTier {
    /// True iff this tier meets or exceeds the feature's minimum tier.
    func unlocks(_ feature: Feature) -> Bool {
        self >= feature.minimumTier
    }
}
