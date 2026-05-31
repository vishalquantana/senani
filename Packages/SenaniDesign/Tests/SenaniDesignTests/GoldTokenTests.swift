import Testing
@testable import SenaniDesign

@Test func goldHexConstantsMatchBrandPalette() {
    // The brand source of truth: landing/index.html :root.
    #expect(Gold.baseHex == "#d4af37")
    #expect(Gold.highlightHex == "#f4dd95")
    #expect(Gold.shadowHex == "#9c7a2e")
}

@Test func goldBaseResolvesToBrandRGBA() {
    let c = HexColor.rgba(hex: Gold.baseHex)
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.g - 175.0/255.0) < 0.001)
    #expect(abs(c.b - 55.0/255.0) < 0.001)
}

@Test func gradientStopsRunHighlightToShadow() {
    // The CSS --gold-grad goes f4dd95 -> d4af37 (45%) -> 9c7a2e.
    #expect(Gold.gradientStops.first == Gold.highlightHex)
    #expect(Gold.gradientStops.last == Gold.shadowHex)
    #expect(Gold.gradientStops.count == 3)
}
