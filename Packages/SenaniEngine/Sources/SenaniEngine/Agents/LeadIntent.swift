import Foundation

/// What the prospect appears to want. Closed set, enforced in the prompt and
/// re-validated on parse (JSONSchema cannot pin an enum). Unknown -> .info.
public enum LeadIntent: String, CaseIterable, Sendable, Equatable {
    case evaluating   // actively comparing / asking detailed questions
    case ready        // ready to buy / wants pricing or a contract now
    case info         // general inquiry / early-stage interest (neutral default)
    case spam         // not a real lead

    /// Case-insensitive lookup; unknown/blank -> .info (neutral safe fallback).
    public static func parse(_ raw: String) -> LeadIntent {
        LeadIntent(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .info
    }
}

/// Lead temperature derived from the 0–100 score. Thresholds: Hot ≥ 70, Warm 40–69, Cold ≤ 39.
public enum LeadTier: String, CaseIterable, Sendable, Equatable {
    case hot, warm, cold

    public init(score: Int) {
        switch score {
        case 70...: self = .hot
        case 40..<70: self = .warm
        default: self = .cold       // <= 39, and any negative (clamped upstream anyway)
        }
    }

    /// The reversible Gmail label the agent proposes, e.g. "Senani/Lead/Hot".
    public var label: String { "Senani/Lead/\(rawValue.capitalized)" }
}
