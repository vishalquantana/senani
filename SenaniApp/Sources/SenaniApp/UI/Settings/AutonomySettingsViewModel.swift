import SwiftUI
import Observation
import SenaniRules

/// Owns the Settings autonomy section. Reads/writes per-agent Autonomy through
/// the AutonomySettingsStore and exposes a Binding<Autonomy> per agent that the
/// AutonomyDial drives. Pure of any store construction — wired from the store.
@MainActor
@Observable
public final class AutonomySettingsViewModel {
    public private(set) var rows: [AgentAutonomy] = []

    private let store: AutonomySettingsStore

    public init(store: AutonomySettingsStore) {
        self.store = store
    }

    /// Live wiring: uses the composition root's autonomy store via the
    /// `autonomyForAgent` closure's backing store. AppEnvironment exposes the
    /// store directly for the Settings screen (Task 6 wires `autonomySettings`).
    public convenience init(environment env: AppEnvironment) {
        self.init(store: env.autonomySettings)
    }

    public func refresh() {
        rows = AgentCatalog.phase1.map { agent in
            AgentAutonomy(agentId: agent.id, displayName: agent.displayName,
                          autonomy: store.autonomy(forAgent: agent.id))
        }
    }

    /// A binding the AutonomyDial consumes; writes persist immediately and refresh the rows.
    public func binding(forAgent agentId: String) -> Binding<Autonomy> {
        Binding<Autonomy>(
            get: { [store] in store.autonomy(forAgent: agentId) },
            set: { [weak self] newValue in
                guard let self else { return }
                self.store.setAutonomy(newValue, forAgent: agentId)
                self.refresh()
            })
    }
}
