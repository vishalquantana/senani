import Foundation

public enum TriageCategory: String, CaseIterable, Sendable, Equatable {
    case lead, booking, proposal, newsletter, personal, other

    public var label: String { "Senani/Category/\(rawValue.capitalized)" }

    /// Every category label. Used by signal-driven agents (ReplyDrafter, Invoice, …) that aren't
    /// bound to a single triage category — they subscribe to all of them and let `wakesFor` gate firing.
    public static let allLabels: Set<String> = Set(TriageCategory.allCases.map(\.label))

    public static func parse(_ raw: String) -> TriageCategory {
        TriageCategory(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }
}

public enum TriagePriority: String, CaseIterable, Sendable, Equatable {
    case high, normal, low

    public var label: String { "Senani/Priority/\(rawValue.capitalized)" }

    public static func parse(_ raw: String) -> TriagePriority {
        TriagePriority(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .normal
    }
}
