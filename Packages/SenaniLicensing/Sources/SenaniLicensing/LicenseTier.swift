import Foundation

/// The two purchasable tiers. Raw value is the stable wire string embedded in a
/// signed license payload. Ordered so `.pro > .core`: a Pro key satisfies any
/// requirement a Core key does (Pro is a superset).
public enum LicenseTier: String, Sendable, Codable, CaseIterable, Comparable {
    case core   // $99 — Phase-1/2 agents
    case pro    // $199 — Phase-1/2 + Phase-3 sales suite

    private var rank: Int {
        switch self {
        case .core: return 0
        case .pro:  return 1
        }
    }

    public static func < (lhs: LicenseTier, rhs: LicenseTier) -> Bool {
        lhs.rank < rhs.rank
    }
}
