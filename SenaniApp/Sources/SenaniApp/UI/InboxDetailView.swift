import SwiftUI
import SenaniRules
import SenaniDesign
import SenaniStore

struct InboxDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let messageID: Message.ID?

    var body: some View {
        Group {
            if let messageID, let message = try? env.messages.fetch(id: messageID) {
                let thread = (try? env.messages.thread(id: message.threadId)) ?? [message]
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                CategoryChip(detectCategory(message))
                                Spacer()
                                Text(formatFullDate(message.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(message.subject)
                                .font(.senaniTitle)
                                .foregroundStyle(Color.senaniInk)

                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(message.from)
                                        .fontWeight(.semibold)
                                    Text("to: \(message.to.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(thread) { threadMessage in
                                ThreadMessageView(message: threadMessage)
                            }
                        }

                        Spacer(minLength: 40)

                        if let insight = findInsight(for: message) {
                            GlassPanel(style: .compact) {
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack {
                                        Image(systemName: "sparkles")
                                        Text("AGENT INSIGHT")
                                            .font(.system(size: 11, weight: .bold))
                                            .kerning(2)
                                    }
                                    .foregroundStyle(Gold.base)

                                    Text(insight.text)
                                        .font(.senaniBody)
                                        .foregroundStyle(Color.senaniInk)

                                    if insight.proposal != nil {
                                        HStack(spacing: 12) {
                                            PrimaryButton("Approve & send") {
                                            }
                                            Button("Edit") { }
                                                .buttonStyle(.bordered)
                                        }
                                    }
                                }
                                .padding(20)
                            }
                        }
                    }
                    .padding(40)
                    .frame(maxWidth: 800)
                }
                .background(Color.senaniSurface)
            } else {
                Text("Select a message to read")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detectCategory(_ message: Message) -> SenaniDesign.Category {
        let prefix = "Senani/Category/"
        let name = message.labels
            .first { $0.hasPrefix(prefix) }?
            .replacingOccurrences(of: prefix, with: "") ?? "Inbox"
        switch name {
        case "Lead": return .lead
        case "Booking": return .booking
        case "Proposal": return .proposal
        default: return .other(name)
        }
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private struct Insight {
        let text: String
        let proposal: Proposal?
    }

    private func findInsight(for message: Message) -> Insight? {
        // In Phase 1, we find the first pending proposal for this message
        if let pending = try? env.approvals.pending().first(where: { $0.proposal.message.id == message.id }) {
            let p = pending.proposal
            switch p.action {
            case .reply(let body):
                return Insight(text: "Drafted a reply in your voice:\n\n\(body)", proposal: p)
            default:
                return Insight(text: "Suggested action: \(p.action)", proposal: p)
            }
        }
        return nil
    }
}

private struct ThreadMessageView: View {
    let message: Message

    var body: some View {
        GlassPanel(style: .compact) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.isFromUser ? "You" : message.from)
                        .font(.headline)
                        .foregroundStyle(Color.senaniInk)
                    Spacer()
                    Text(message.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(Color.senaniMuted)
                }

                Text(message.body)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniInk)
                    .lineSpacing(6)
            }
            .padding(18)
        }
    }
}
