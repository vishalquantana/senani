import SwiftUI
import SenaniRules

/// The display model for the autonomy ladder (ARCHITECTURE.md: Suggest → Draft → Auto).
/// Maps the human-facing labels to the FROZEN SenaniRules.Autonomy cases.
///
/// IMPORTANT: SenaniRules.Autonomy's real cases are `.ask / .prepare / .auto`
/// (the source names `prepare` to avoid colliding with the `draft(...)` action).
/// The dial shows "Suggest / Draft / Auto" over them. This is the single seam
/// coupling SenaniDesign to SenaniRules; if the enum is ever re-frozen, only this maps.
public enum AutonomyOption: CaseIterable, Sendable, Equatable {
    case suggest
    case draft
    case auto

    public var label: String {
        switch self {
        case .suggest: return "Suggest"
        case .draft: return "Draft"
        case .auto: return "Auto"
        }
    }

    /// Display option → frozen Autonomy case.
    public var autonomy: Autonomy {
        switch self {
        case .suggest: return .ask
        case .draft: return .prepare
        case .auto: return .auto
        }
    }

    /// Frozen Autonomy case → display option (total).
    public init(autonomy: Autonomy) {
        switch autonomy {
        case .ask: self = .suggest
        case .prepare: self = .draft
        case .auto: self = .auto
        }
    }
}

/// Per-agent autonomy ladder control (reconciliation §3). A segmented picker
/// over Suggest/Draft/Auto that binds a SenaniRules.Autonomy.
public struct AutonomyDial: View {
    @Binding private var autonomy: Autonomy

    public init(_ autonomy: Binding<Autonomy>) {
        self._autonomy = autonomy
    }

    /// Pure binding adapter (testable without rendering): bridges a Binding<Autonomy>
    /// to a Binding<AutonomyOption> so the Picker can drive it and writes flow back.
    public static func selectionBinding(for autonomy: Binding<Autonomy>) -> Binding<AutonomyOption> {
        Binding<AutonomyOption>(
            get: { AutonomyOption(autonomy: autonomy.wrappedValue) },
            set: { autonomy.wrappedValue = $0.autonomy }
        )
    }

    public var body: some View {
        Picker("Autonomy", selection: AutonomyDial.selectionBinding(for: $autonomy)) {
            ForEach(AutonomyOption.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(Gold.base)
        .font(.senaniBody)
    }
}

#Preview("AutonomyDial") {
    struct DialPreview: View {
        @State var autonomy: Autonomy = .prepare
        var body: some View {
            VStack(spacing: 16) {
                AutonomyDial($autonomy)
                Text("Bound: \(autonomy.rawValue)")
                    .font(.senaniMono).foregroundStyle(Color.senaniMuted)
            }
            .padding(40)
            .background(Color.senaniSurface)
        }
    }
    return DialPreview()
}
