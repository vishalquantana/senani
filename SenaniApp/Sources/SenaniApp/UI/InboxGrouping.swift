import Foundation
import SenaniDesign
import SenaniRules
import SenaniStore

enum InboxGrouping {
    static func buildSections(
        messages: [Message],
        approvals: [StoredProposal] = [],
        auditEntries: [AuditEntry] = []
    ) -> [InboxSection] {
        let rows = messages.map {
            buildRow(message: $0, approvals: approvals, auditEntries: auditEntries)
        }
        let grouped = Dictionary(grouping: rows, by: \.category.title)

        return grouped.keys
            .sorted { categorySortKey($0) < categorySortKey($1) }
            .compactMap { title in
                guard let rows = grouped[title] else { return nil }
                let sortedRows = rows.sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                    if lhs.date != rhs.date { return lhs.date > rhs.date }
                    return lhs.id < rhs.id
                }
                return InboxSection(category: sortedRows[0].category, rows: sortedRows)
            }
    }

    static func group(_ messages: [Message]) -> [InboxGrouping.Section] {
        buildSections(messages: messages).map { section in
            Section(
                category: section.category,
                messages: section.rows.compactMap { row in
                    messages.first { $0.id == row.id }
                }
            )
        }
    }

    static func buildRow(
        message: Message,
        approvals: [StoredProposal] = [],
        auditEntries: [AuditEntry] = []
    ) -> InboxRow {
        InboxRow(
            id: message.id,
            senderName: senderName(from: message.from),
            subject: message.subject.isEmpty ? "(No subject)" : message.subject,
            snippet: snippet(from: message.body),
            category: category(from: message.labels),
            priority: priority(from: message.labels),
            status: status(for: message, approvals: approvals, auditEntries: auditEntries),
            date: message.date
        )
    }

    static func category(from labels: [String]) -> SenaniDesign.Category {
        guard let suffix = firstLabelSuffix(in: labels, prefix: "Senani/Category/") else {
            return .other("Uncategorized")
        }

        switch suffix {
        case "Lead": return .lead
        case "Booking": return .booking
        case "Proposal": return .proposal
        default: return .other(suffix)
        }
    }

    static func priority(from labels: [String]) -> Priority {
        guard let suffix = firstLabelSuffix(in: labels, prefix: "Senani/Priority/") else {
            return .normal
        }

        switch suffix {
        case "High": return .high
        case "Low": return .low
        default: return .normal
        }
    }

    static func status(
        for message: Message,
        approvals: [StoredProposal],
        auditEntries: [AuditEntry]
    ) -> AgentStatus {
        if approvals.contains(where: { $0.proposal.message.id == message.id }) {
            return .queued
        }

        if auditEntries.contains(where: { entry in
            entry.record.messageId == message.id && entry.record.action.isDraftLike
        }) {
            return .drafted
        }

        return .none
    }

    static func senderName(from rawSender: String) -> String {
        let trimmed = rawSender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown sender" }

        if let angle = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<angle]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
            if !name.isEmpty { return name }
        }

        if let at = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<at])
        }

        return trimmed
    }

    static func snippet(from body: String, limit: Int = 120) -> String {
        let collapsed = body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 3))) + "..."
    }

    struct Section: Identifiable, Sendable {
        let category: SenaniDesign.Category
        let messages: [Message]
        var id: String { category.title }
    }

    private static func firstLabelSuffix(in labels: [String], prefix: String) -> String? {
        labels
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func categorySortKey(_ title: String) -> (Int, String) {
        switch title {
        case "Lead": return (0, title)
        case "Booking": return (1, title)
        case "Proposal": return (2, title)
        case "Uncategorized": return (4, title)
        default: return (3, title)
        }
    }
}

private extension Action {
    var isDraftLike: Bool {
        switch self {
        case .draft, .reply, .forward, .send:
            return true
        case .label, .archive, .markRead, .markUnread, .star, .unstar, .move,
             .flagNeedsReply, .fileAttachment, .parseDoc, .runAgent, .markSpam,
             .localWebhook:
            return false
        }
    }
}
