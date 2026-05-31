import Testing
import SwiftUI
@testable import SenaniDesign

@Test func colorTokenHexMatchesBrandPalette() {
    #expect(SenaniTokens.inkHex == "#ece7dc")
    #expect(SenaniTokens.surfaceHex == "#08080b")
    #expect(SenaniTokens.accentHex == "#e8c97a")
    #expect(SenaniTokens.mutedHex == "#9b948a")
}

@Test func surfaceTokenResolvesToNearBlackBrandBackground() {
    let c = HexColor.rgba(hex: SenaniTokens.surfaceHex)
    #expect(abs(c.r - 8.0/255.0) < 0.001)
    #expect(abs(c.g - 8.0/255.0) < 0.001)
    #expect(abs(c.b - 11.0/255.0) < 0.001)
}

@Test func colorTokensAreReachableViaExtension() {
    // Compile-time proof the public extension symbols exist (reconciliation §3 names).
    _ = Color.senaniInk
    _ = Color.senaniSurface
    _ = Color.senaniAccent
    _ = Color.senaniMuted
}

@Test func fontTokensAreReachableViaExtension() {
    _ = Font.senaniTitle
    _ = Font.senaniBody
    _ = Font.senaniMono
}
