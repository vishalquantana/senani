import Testing
@testable import SenaniLicensing

@Test func statusEquatableDistinguishesTiers() {
    #expect(LicenseStatus.valid(.core) == .valid(.core))
    #expect(LicenseStatus.valid(.core) != .valid(.pro))
    #expect(LicenseStatus.invalid != .tampered)
    #expect(LicenseStatus.malformed != .invalid)
}
