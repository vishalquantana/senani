import Testing
import SwiftUI
import SenaniRules
@testable import SenaniDesign

@Test func optionsAreOrderedSuggestDraftAuto() {
    #expect(AutonomyOption.allCases == [.suggest, .draft, .auto])
}

@Test func labelsMatchTrustLadderWording() {
    #expect(AutonomyOption.suggest.label == "Suggest")
    #expect(AutonomyOption.draft.label == "Draft")
    #expect(AutonomyOption.auto.label == "Auto")
}

@Test func optionMapsToFrozenAutonomyCases() {
    // The load-bearing mapping: display option -> real SenaniRules.Autonomy case.
    #expect(AutonomyOption.suggest.autonomy == .ask)
    #expect(AutonomyOption.draft.autonomy == .prepare)
    #expect(AutonomyOption.auto.autonomy == .auto)
}

@Test func autonomyMapsBackToOptionTotally() {
    #expect(AutonomyOption(autonomy: .ask) == .suggest)
    #expect(AutonomyOption(autonomy: .prepare) == .draft)
    #expect(AutonomyOption(autonomy: .auto) == .auto)
}

@Test func roundTripThroughBothDirectionsIsLossless() {
    for option in AutonomyOption.allCases {
        #expect(AutonomyOption(autonomy: option.autonomy) == option)
    }
    for autonomy in [Autonomy.ask, .prepare, .auto] {
        #expect(AutonomyOption(autonomy: autonomy).autonomy == autonomy)
    }
}

@Test @MainActor func dialSelectionWritesThroughTheBoundAutonomy() {
    // Drive the dial's selection seam against a real Binding<Autonomy> backed by a var.
    // We use a @MainActor context so the captured var is safe and Binding init is safe.
    var stored: Autonomy = .ask
    let binding = Binding<Autonomy>(get: { stored }, set: { stored = $0 })

    // The view exposes its selection as a Binding<AutonomyOption> derived from the
    // Autonomy binding; assigning an option must write the mapped case back.
    let selection = AutonomyDial.selectionBinding(for: binding)
    #expect(selection.wrappedValue == .suggest)   // .ask -> .suggest

    selection.wrappedValue = .auto
    #expect(stored == .auto)                       // wrote through

    selection.wrappedValue = .draft
    #expect(stored == .prepare)                    // .draft -> .prepare
}

@Test @MainActor func dialBuildsWithABinding() {
    var stored: Autonomy = .prepare
    let binding = Binding<Autonomy>(get: { stored }, set: { stored = $0 })
    _ = AutonomyDial(binding).body
}
