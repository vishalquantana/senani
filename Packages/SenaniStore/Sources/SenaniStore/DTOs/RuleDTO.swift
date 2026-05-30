import SenaniRules

public struct RuleDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var conditions: ConditionsDTO
    public var actions: [ActionDTO]
    public var autonomy: String
    public var runOn: String

    public init(core: Rule) {
        id = core.id
        name = core.name
        enabled = core.enabled
        conditions = ConditionsDTO(core: core.conditions)
        actions = core.actions.map(ActionDTO.init(core:))
        autonomy = core.autonomy.rawValue
        runOn = core.runOn.rawValue
    }

    public func toCore() -> Rule {
        Rule(
            id: id,
            name: name,
            enabled: enabled,
            conditions: conditions.toCore(),
            actions: actions.map { $0.toCore() },
            autonomy: Autonomy(rawValue: autonomy) ?? .ask,
            runOn: RunOn(rawValue: runOn) ?? .incoming
        )
    }
}
