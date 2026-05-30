/// Per-rule autonomy ladder. New rules default to `.ask`.
/// `prepare` stages reversible actions for one-click commit; `auto` fires them silently.
/// (Named `prepare` rather than `draft` to avoid colliding with the `draft(...)` action.)
public enum Autonomy: String, Sendable, Equatable {
    case ask
    case prepare
    case auto
}

/// Which messages a rule runs against.
public enum RunOn: String, Sendable, Equatable {
    case incoming
    case existing
    case both
}

/// A user-authored automation: WHEN <conditions> DO <actions> @ <autonomy>.
public struct Rule: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public var conditions: Conditions
    public var actions: [Action]
    public var autonomy: Autonomy
    public var runOn: RunOn

    public init(
        id: String, name: String, enabled: Bool, conditions: Conditions,
        actions: [Action], autonomy: Autonomy, runOn: RunOn
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.actions = actions
        self.autonomy = autonomy
        self.runOn = runOn
    }
}
