import Testing
import SwiftUI
@testable import SenaniApp

@MainActor
@Test func navigationItemsCoverTheFourSections() {
    #expect(NavigationItem.allCases.contains(.inbox))
    #expect(NavigationItem.inbox.title == "Inbox")
    #expect(NavigationItem.settings.systemImage == "gearshape")
}

@MainActor
@Test func rootSceneInstantiatesWithPreviewEnvironment() {
    let env = AppEnvironment.preview()
    // Constructing the view tree with the injected environment must not crash.
    let _ = RootScene().environmentObject(env)
    #expect(env.selectedItem == .inbox)   // default selection
}
