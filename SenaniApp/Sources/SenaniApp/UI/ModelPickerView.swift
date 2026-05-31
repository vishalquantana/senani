import SwiftUI
import SenaniModelCatalog

@MainActor
struct ModelPickerView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var loading = true
    @State private var loadError: String?
    @State private var recommendation: RecommendationResult?
    @State private var activeDownloadId: String?
    @State private var progress: Double = 0
    @State private var activatedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose your local model")
                .font(.title2).bold()
            Text("Recommended for this Mac (\(env.tier.displayName) RAM). Runs fully on-device.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Fetching mlx-community catalog…")
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load the model list.").bold()
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
        } else if let rec = recommendation {
            if rec.models.isEmpty {
                Text("No compatible Gemma 4-bit models found for this tier.")
                    .foregroundStyle(.secondary)
            } else {
                List(rec.models) { model in
                    row(for: model, isSuggested: model.id == rec.suggestedDefault?.id)
                }
            }
        }
    }

    private func row(for model: ModelInfo, isSuggested: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.shortName).font(.headline)
                    if isSuggested {
                        Text("Recommended")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.2)))
                    }
                }
                Text("\(ModelInfo.formatBytes(model.sizeBytes)) · fits your \(env.tier.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if activatedId == model.id || (env.hasModel && env.choices.load()?.modelId == model.id) {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if activeDownloadId == model.id {
                ProgressView(value: progress).frame(width: 120)
            } else {
                Button("Use this model") { Task { await use(model) } }
                    .disabled(activeDownloadId != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        loading = true; loadError = nil
        do {
            recommendation = try await env.catalog.recommended(tier: env.tier)
        } catch {
            loadError = String(describing: error)
        }
        loading = false
    }

    private func use(_ model: ModelInfo) async {
        activeDownloadId = model.id; progress = 0
        do {
            try await env.modelManager.chooseAndActivate(model) { p in
                Task { @MainActor in self.progress = p.fraction }
            }
            activatedId = model.id
        } catch {
            loadError = "Download/activation failed: \(error)"
        }
        activeDownloadId = nil
    }
}

#Preview {
    ModelPickerView().environmentObject(AppEnvironment.preview())
}
