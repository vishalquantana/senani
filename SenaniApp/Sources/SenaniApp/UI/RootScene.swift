import SwiftUI

/// Top-level navigation skeleton: a sidebar of the four sections plus the
/// selected placeholder destination. Selection lives on AppEnvironment so the
/// composition root remains the single source of state.
struct RootScene: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: Binding(
                get: { env.selectedItem },
                set: { env.selectedItem = $0 ?? .inbox }
            )) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .navigationTitle("Senani")
        } content: {
            content(for: env.selectedItem)
                .navigationSplitViewColumnWidth(min: 300, ideal: 350)
        } detail: {
            detail(for: env.selectedItem)
        }
    }

    @ViewBuilder
    private func content(for item: NavigationItem) -> some View {
        switch item {
        case .inbox: InboxView()
        case .approvals: ApprovalQueueView()
        case .activity: ActivityLogView()
        case .settings: SettingsView()
        case .crm: PipelineView(deals: (try? env.pipeline.all()) ?? [])
        case .outreach: OutreachView()
        }
    }

    @ViewBuilder
    private func detail(for item: NavigationItem) -> some View {
        switch item {
        case .inbox: InboxDetailView(messageID: env.selectedMessageID)
        case .crm:
            ZStack {
                Color.senaniSurface.ignoresSafeArea()
                Text("Select a deal to view thread")
                    .foregroundStyle(.secondary)
            }
        case .approvals, .activity, .settings, .outreach:
            ZStack {
                Color.senaniSurface.ignoresSafeArea()
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    RootScene().environmentObject(AppEnvironment.preview())
}
