import SwiftUI
import SenaniRules
import SenaniDesign

/// Settings screen. This plan owns the AUTONOMY section (a dial per agent);
/// account/model sections are placeholders owned by onboarding/MLX-picker plans.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: AutonomySettingsViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                GlassPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Agent autonomy")
                            .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Suggest holds everything for approval · Draft prepares reversible actions · Auto runs them. Outbound mail always waits for you.")
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)

                        ForEach(model?.rows ?? []) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.displayName).font(.senaniBody).foregroundStyle(Color.senaniInk)
                                if let model {
                                    AutonomyDial(model.binding(forAgent: row.agentId))
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                GlassPanel(style: .compact) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account & model").font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Connect Gmail and choose a model — configured in onboarding.")
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)
                    }
                    .padding(20)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = AutonomySettingsViewModel(environment: env) }
            model?.refresh()
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppEnvironment.preview())
}
