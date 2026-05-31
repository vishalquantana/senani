import SwiftUI
import SenaniLicensing

/// STUB activation screen: paste a key, Activate, see status. The full Settings →
/// License management UI (receipts, deactivate, upgrade-to-Pro upsell) is deferred.
public struct ActivationView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var key: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate Senani").font(.title2).bold()
            Text("Paste your license key. Verification is fully offline — no account, no internet.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("XXXXX-XXXXX-XXXXX-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("Activate") { env.licenseState.activate(key) }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                statusLabel
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }

    @ViewBuilder private var statusLabel: some View {
        switch env.licenseState.status {
        case .valid(let tier): Label("Activated — \(tier.rawValue.capitalized)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .invalid:         Label("Invalid key", systemImage: "xmark.seal").foregroundStyle(.red)
        case .tampered:        Label("Tampered key", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .malformed:       Label("Not a valid key format", systemImage: "questionmark.diamond").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ActivationView().environmentObject(AppEnvironment.preview())
}
