import Testing
@testable import SenaniLicensing

@Test func tierRawValuesAreStableWireStrings() {
    #expect(LicenseTier.core.rawValue == "core")
    #expect(LicenseTier.pro.rawValue == "pro")
    #expect(LicenseTier(rawValue: "pro") == .pro)
    #expect(LicenseTier(rawValue: "enterprise") == nil)
}

@Test func proOutranksCore() {
    #expect(LicenseTier.pro > LicenseTier.core)
    #expect(LicenseTier.core < LicenseTier.pro)
    #expect(LicenseTier.pro >= LicenseTier.pro)
}
