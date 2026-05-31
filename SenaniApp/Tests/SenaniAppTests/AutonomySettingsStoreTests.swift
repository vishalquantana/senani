import Testing
import Foundation
@testable import SenaniApp
import SenaniRules

private func freshSuite() -> UserDefaults {
    let name = "senani.autonomy.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func unsetAgentDefaultsToAsk() {
    let store = AutonomySettingsStore(defaults: freshSuite())
    #expect(store.autonomy(forAgent: "reply-drafter") == .ask)
}

@Test func setThenGetRoundTrips() {
    let d = freshSuite()
    let store = AutonomySettingsStore(defaults: d)
    store.setAutonomy(.auto, forAgent: "triage")
    store.setAutonomy(.prepare, forAgent: "reply-drafter")
    #expect(store.autonomy(forAgent: "triage") == .auto)
    #expect(store.autonomy(forAgent: "reply-drafter") == .prepare)
    // Persists across a fresh store over the SAME suite.
    let reopened = AutonomySettingsStore(defaults: d)
    #expect(reopened.autonomy(forAgent: "triage") == .auto)
}

@Test func corruptOrUnknownRawValueFallsBackToAsk() {
    let d = freshSuite()
    d.set("nonsense", forKey: "senani.autonomy.triage")
    let store = AutonomySettingsStore(defaults: d)
    #expect(store.autonomy(forAgent: "triage") == .ask)
}

@Test func inMemoryFactoryIsIsolated() {
    let a = AutonomySettingsStore.inMemory()
    let b = AutonomySettingsStore.inMemory()
    a.setAutonomy(.auto, forAgent: "triage")
    #expect(b.autonomy(forAgent: "triage") == .ask)   // separate suites
}

// Finding 4 wiring: the Orchestrator uses `explicitAutonomy(forAgent:)`, which returns nil when the
// user never set a dial — so an unset agent keeps its own static autonomy instead of being silently
// forced to a default, while a user-set dial overrides routing.
@Test func explicitAutonomyIsNilWhenUnsetAndValueWhenSet() {
    let store = AutonomySettingsStore(defaults: freshSuite())
    #expect(store.explicitAutonomy(forAgent: "triage") == nil)        // unset → fall back to static
    store.setAutonomy(.auto, forAgent: "reply-drafter")
    #expect(store.explicitAutonomy(forAgent: "reply-drafter") == .auto)  // set → overrides
    #expect(store.explicitAutonomy(forAgent: "triage") == nil)        // other agent still unset
}

@Test func explicitAutonomyIgnoresCorruptValue() {
    let d = freshSuite()
    d.set("nonsense", forKey: "senani.autonomy.triage")
    let store = AutonomySettingsStore(defaults: d)
    #expect(store.explicitAutonomy(forAgent: "triage") == nil)
}
