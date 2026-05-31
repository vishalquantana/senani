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
