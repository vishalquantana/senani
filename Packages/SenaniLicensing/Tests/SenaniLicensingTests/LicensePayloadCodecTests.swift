import Testing
import Foundation
@testable import SenaniLicensing

@Test func canonicalBytesAreDeterministicAndRoundTrip() throws {
    let payload = LicensePayload(
        licenseID: "LIC-0001",
        tier: .pro,
        issued: Date(timeIntervalSince1970: 1_700_000_000),
        buyerEmail: "ramesh@quantana.in",
        seats: 1
    )
    let a = try payload.canonicalBytes()
    let b = try payload.canonicalBytes()
    #expect(a == b)                                  // deterministic: same input → same bytes
    let decoded = try LicensePayload(canonicalBytes: a)
    #expect(decoded == payload)                      // round-trips exactly
}

@Test func canonicalJSONHasSortedKeysAndIntegerSeconds() throws {
    let payload = LicensePayload(
        licenseID: "Z", tier: .core,
        issued: Date(timeIntervalSince1970: 1_700_000_000),
        buyerEmail: nil, seats: nil
    )
    let json = String(decoding: try payload.canonicalBytes(), as: UTF8.self)
    // keys appear in sorted order; optionals omitted when nil; issued is integer epoch seconds
    #expect(json == #"{"issued":1700000000,"licenseID":"Z","tier":"core"}"#)
}

@Test func malformedBytesThrow() {
    #expect(throws: (any Error).self) {
        _ = try LicensePayload(canonicalBytes: Data("not json".utf8))
    }
}
