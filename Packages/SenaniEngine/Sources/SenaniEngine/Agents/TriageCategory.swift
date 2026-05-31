import Foundation

public enum TriageCategory: String, CaseIterable, Sendable, Equatable {
    case lead, booking, proposal, newsletter, personal, other

    public var label: String { "Senani/Category/\(rawValue.capitalized)" }

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
