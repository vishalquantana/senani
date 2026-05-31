import Testing
import SwiftUI
@testable import SenaniDesign

@Test func primaryButtonSpecMatchesBrandCTA() {
    let s = PrimaryButtonStyleSpec.default
    #expect(s.cornerRadius == 11)        // .btn border-radius:11px
    #expect(s.textHex == "#1a1408")      // .btn-gold color
    #expect(s.horizontalPadding == 20)
    #expect(s.verticalPadding == 11)
}

@Test @MainActor func primaryButtonInvokesItsAction() {
    var tapped = 0
    let button = PrimaryButton("Approve") { tapped += 1 }
    button.action()                      // the stored action closure is the wiring seam
    #expect(tapped == 1)
}

@Test @MainActor func primaryButtonBuilds() {
    _ = PrimaryButton("Star on GitHub") { }.body
}
