import SwiftUI
import SenaniRules
import SenaniDesign

/// Settings screen. This plan owns the AUTONOMY section (a dial per agent);
/// account/model sections are placeholders owned by onboarding/MLX-picker plans.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: AutonomySettingsViewModel?
    @State private var showModelPicker = false

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
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local Model").font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        
                        if env.hasModel {
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundStyle(Gold.base)
                                Text(env.choices.load()?.modelId ?? "Active")
                                    .font(.senaniBody)
                            }
                        } else {
                            Text("No model installed. Live inference is disabled.")
                                .font(.system(size: 12)).foregroundStyle(.red)
                        }
                        
                        Button("Manage Models…") {
                            showModelPicker = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(20)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView()
                .frame(width: 600, height: 500)
        }
        .task {
            if model == nil { model = AutonomySettingsViewModel(environment: env) }
            model?.refresh()
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppEnvironment.preview())
}
