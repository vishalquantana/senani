import Testing
import Foundation
@testable import SenaniLicensing

@Test func saveLoadClearRoundTrips() throws {
    // Use a unique service per run so concurrent test runs don't collide.
    let service = "in.quantana.senani.license.test.\(UUID().uuidString)"
    let store = LicenseKeychainStore(service: service)
    defer { try? store.clear() }

    #expect(try store.load() == nil)             // empty to start
    try store.save("ABCDE-FGHIJ-KLMNP")
    #expect(try store.load() == "ABCDE-FGHIJ-KLMNP")
    try store.save("NEWKE-Y0001")                // overwrite, not duplicate
    #expect(try store.load() == "NEWKE-Y0001")
    try store.clear()
    #expect(try store.load() == nil)             // cleared
}
