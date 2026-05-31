import SwiftUI
import SenaniRules
import SenaniDesign

struct MessageRow: View {
    let row: InboxRow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.senderName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? .black : Color.senaniInk)
                Spacer()
                Text(formatDate(row.date))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .black.opacity(0.6) : Color.senaniMuted)
            }

            Text(row.subject)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .black.opacity(0.8) : Color.senaniInk.opacity(0.9))
                .lineLimit(1)

            Text(row.snippet)
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
    @StateObject private var viewModel = InboxCockpitViewModel()

    var body: some View {
        List(selection: $env.selectedMessageID) {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    InboxErrorBanner(message: errorMessage)
                }
            }

            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        MessageRow(row: row, isSelected: env.selectedMessageID == row.id)
                            .tag(row.id)
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
            // Reads run on the view model (off `body`) with proper error
            // surfacing — a failed read shows a banner instead of an empty list.
            viewModel.bind(environment: env)
            env.selectedMessageID = await viewModel.refresh(selectedMessageID: env.selectedMessageID)
        }
        .onChange(of: env.selectedMessageID) { _, newValue in
            viewModel.refreshThread(selectedMessageID: newValue)
        }
    }
}

private struct InboxErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load inbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.senaniInk)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.senaniMuted)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    InboxView()
        .environmentObject(AppEnvironment.preview())
}
