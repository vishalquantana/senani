import SwiftUI
import SenaniRules
import SenaniDesign

struct MessageRow: View {
    let message: Message
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.from)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? .black : Color.senaniInk)
                Spacer()
                Text(formatDate(message.date))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .black.opacity(0.6) : Color.senaniMuted)
            }

            Text(message.subject)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .black.opacity(0.8) : Color.senaniInk.opacity(0.9))
                .lineLimit(1)

            Text(message.body)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .black.opacity(0.6) : Color.senaniMuted)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Gold.base : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct InboxView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var messages: [Message] = []

    var body: some View {
        let sections = InboxGrouping.group(messages)

        List(selection: $env.selectedMessageID) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.messages) { message in
                        MessageRow(message: message, isSelected: env.selectedMessageID == message.id)
                            .tag(message.id)
                    }
                } header: {
                    HStack {
                        CategoryChip(section.category)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Inbox")
        .task {
            // Load messages from store
            try? messages = env.messages.all()
        }
    }
}
