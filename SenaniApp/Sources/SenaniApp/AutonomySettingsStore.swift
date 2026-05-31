import Foundation
import SenaniRules

/// Persists each agent's user-chosen Autonomy dial. Backed by UserDefaults.
public struct AutonomySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Production store over the standard suite.
    public static func live() -> AutonomySettingsStore {
        AutonomySettingsStore(defaults: .standard)
    }

    /// Isolated in-memory store for previews/tests.
    public static func inMemory() -> AutonomySettingsStore {
        let name = "senani.autonomy.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return AutonomySettingsStore(defaults: d)
    }

    private func key(_ agentId: String) -> String { "senani.autonomy.\(agentId)" }

    /// The agent's chosen Autonomy, or `.ask` if unset/corrupt.
    public func autonomy(forAgent agentId: String) -> Autonomy {
        guard let raw = defaults.string(forKey: key(agentId)),
              let value = Autonomy(rawValue: raw) else { return .ask }
        return value
    }

    public func setAutonomy(_ autonomy: Autonomy, forAgent agentId: String) {
        defaults.set(autonomy.rawValue, forKey: key(agentId))
    }
}

/// The agents the Settings autonomy section lists. Phase 1 ships Triage + Reply
/// Drafter; later agent plans append their ids here.
public enum AgentCatalog {
    public static let phase1: [(id: String, displayName: String)] = [
        ("triage", "Triage"),
        ("reply-drafter", "Reply Drafter"),
    ]
}
