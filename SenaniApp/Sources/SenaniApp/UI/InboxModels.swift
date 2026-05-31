import Foundation
import SenaniDesign

enum Priority: Int, Sendable, Equatable, Comparable {
    case high = 0
    case normal = 1
    case low = 2

    var rank: Int { rawValue }

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum AgentStatus: Sendable, Equatable {
    case none
    case drafted
    case queued

    var title: String {
        switch self {
        case .none: return "No action"
        case .drafted: return "Drafted"
        case .queued: return "Queued"
        }
    }
}

struct InboxRow: Identifiable, Sendable, Equatable {
    let id: String
    let senderName: String
    let subject: String
    let snippet: String
    let category: SenaniDesign.Category
    let priority: Priority
    let status: AgentStatus
    let date: Date
}

struct InboxSection: Identifiable, Sendable, Equatable {
    let category: SenaniDesign.Category
    let rows: [InboxRow]

    var id: String { category.title }
}
