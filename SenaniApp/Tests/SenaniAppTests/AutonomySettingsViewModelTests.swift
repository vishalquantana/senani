import Testing
import SwiftUI
@testable import SenaniApp
import SenaniRules

@MainActor
@Test func listsKnownAgentsWithCurrentAutonomy() {
    let store = AutonomySettingsStore.inMemory()
    store.setAutonomy(.auto, forAgent: "triage")
    let vm = AutonomySettingsViewModel(store: store)
    vm.refresh()
    let triage = vm.rows.first { $0.agentId == "triage" }
    #expect(triage != nil)
    #expect(triage?.displayName == "Triage")
    #expect(triage?.autonomy == .auto)
    #expect(vm.rows.contains { $0.agentId == "reply-drafter" })
}

@MainActor
@Test func bindingWritesThroughToTheStoreAndRefreshes() {
    let store = AutonomySettingsStore.inMemory()
    let vm = AutonomySettingsViewModel(store: store)
    vm.refresh()
    let binding = vm.binding(forAgent: "reply-drafter")
    #expect(binding.wrappedValue == .ask)        // default
    binding.wrappedValue = .prepare
    #expect(store.autonomy(forAgent: "reply-drafter") == .prepare)   // persisted
    #expect(vm.rows.first { $0.agentId == "reply-drafter" }?.autonomy == .prepare)  // VM refreshed
}

@MainActor
@Test func autonomyInitFromPreviewEnvironmentBuilds() {
    let env = AppEnvironment.preview()
    let vm = AutonomySettingsViewModel(environment: env)
    vm.refresh()
    #expect(vm.rows.isEmpty == false)
}
