import Testing
@testable import SenaniDesign
import SenaniRules

@Test func packageImportsCompileAndLinkSenaniRules() {
    let autonomy: SenaniRules.Autonomy = .ask
    #expect(autonomy == .ask)
}

@Test func parsesSixDigitHex() {
    let c = HexColor.rgba(hex: "#d4af37")
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.g - 175.0/255.0) < 0.001)
    #expect(abs(c.b - 55.0/255.0) < 0.001)
    #expect(c.a == 1.0)
}

@Test func parsesWithoutLeadingHash() {
    let c = HexColor.rgba(hex: "f4dd95")
    #expect(abs(c.r - 244.0/255.0) < 0.001)
    #expect(abs(c.g - 221.0/255.0) < 0.001)
    #expect(abs(c.b - 149.0/255.0) < 0.001)
}

@Test func parsesEightDigitHexWithAlpha() {
    let c = HexColor.rgba(hex: "#d4af3729")   // ~16% opacity gold (the --line color)
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.a - 41.0/255.0) < 0.001)
}

@Test func malformedHexFallsBackToOpaqueBlackNeverCrashes() {
    let c = HexColor.rgba(hex: "nonsense")
    #expect(c.r == 0 && c.g == 0 && c.b == 0 && c.a == 1.0)
}
