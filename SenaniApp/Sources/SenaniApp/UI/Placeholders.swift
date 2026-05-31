import SwiftUI

/// Phase-0 placeholder destinations. Each reads the injected AppEnvironment to
/// prove the dependency reaches screens; the real cockpit/queue/log/settings
/// screens are separate plans.
struct InboxPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Inbox",
                        detail: "No messages yet. Connect Gmail and pick a model to begin.")
    }
}

struct ApprovalsPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Approvals",
                        detail: "Proposals awaiting your approval will appear here.")
    }
}

struct ActivityPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Activity",
                        detail: "An audit trail of every action runs here.")
    }
}

struct SettingsPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Settings",
                        detail: "Account, model, and autonomy settings.")
    }
}

private struct PlaceholderBody: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.largeTitle.bold())
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
