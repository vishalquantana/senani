import Testing
import SwiftUI
@testable import SenaniDesign

@Test func defaultGlassStyleMatchesBrandMockCard() {
    let s = GlassPanelStyle.default
    #expect(s.cornerRadius == 18)        // .mock-card border-radius:18px
    #expect(s.borderWidth == 1)          // 1px gold edge
    #expect(abs(s.borderOpacity - 0.16) < 0.001) // --line rgba alpha .16
    #expect(abs(s.fillOpacity - 0.045) < 0.001)  // --glass rgba alpha .045
}

@Test func compactGlassStyleHasTighterRadius() {
    let s = GlassPanelStyle.compact
    #expect(s.cornerRadius == 15)        // .agent card radius
    #expect(s.cornerRadius < GlassPanelStyle.default.cornerRadius)
}

@Test @MainActor func glassPanelBuildsWithContent() {
    // Construction guard: the generic View instantiates with arbitrary content.
    let panel = GlassPanel { Text("hello") }
    _ = panel.body   // exercising body must not trap
}

@Test @MainActor func glassPanelAcceptsExplicitStyle() {
    let panel = GlassPanel(style: .compact) { Color.clear }
    #expect(panel.style.cornerRadius == 15)
}
