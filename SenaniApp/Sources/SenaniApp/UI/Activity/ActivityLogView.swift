import SwiftUI
import Foundation
import SenaniDesign

/// The Activity Log screen: a reverse-chronological timeline of every action the
/// engine took or queued. A thin renderer over ActivityLogViewModel.
struct ActivityLogView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: ActivityLogViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activity")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                if let model, model.entries.isEmpty {
                    Text("No activity yet. Every action your agents take will be logged here.")
                        .font(.senaniBody).foregroundStyle(Color.senaniMuted).padding(.vertical, 24)
                }

                ForEach(model?.entries ?? []) { entry in
                    GlassPanel(style: .compact) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.actionSummary)
                                    .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                                Spacer()
                                Text(entry.outcomeLabel)
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.senaniAccent)
                            }
                            Text("\(entry.triggerLabel) · message \(entry.messageId) · \(timestamp(entry.loggedAt))")
                                .font(.system(size: 11)).foregroundStyle(Color.senaniMuted)
                        }
                        .padding(14)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = ActivityLogViewModel(environment: env) }
            await model?.refresh()
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}

#Preview {
    let env = AppEnvironment.preview()
    Task {
        await env.audit.record(.init(action: .reply(body: "Sounds good!"), messageId: "pm1",
                                     trigger: .rule(id: "reply-drafter"), outcome: .queuedForApproval))
        await env.audit.record(.init(action: .label("Lead"), messageId: "pm2",
                                     trigger: .rule(id: "triage"), outcome: .executed))
    }
    return ActivityLogView().environmentObject(env)
}
