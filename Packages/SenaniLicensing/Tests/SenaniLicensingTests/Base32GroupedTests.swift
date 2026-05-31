import Testing
import Foundation
@testable import SenaniLicensing

@Test func encodeDecodeRoundTrips() throws {
    let bytes = Data((0..<37).map { UInt8($0) })   // arbitrary, not a multiple of 5
    let grouped = Base32Grouped.encode(bytes)
    #expect(grouped.contains("-"))                 // grouped into XXXXX-XXXXX blocks
    let decoded = try Base32Grouped.decode(grouped)
    #expect(decoded == bytes)
}

@Test func decodeIsCaseInsensitiveAndIgnoresDashes() throws {
    let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let grouped = Base32Grouped.encode(bytes)
    let lowerNoDash = grouped.lowercased().replacingOccurrences(of: "-", with: "")
    #expect(try Base32Grouped.decode(lowerNoDash) == bytes)
}

@Test func decodeRejectsIllegalCharacters() {
    #expect(throws: (any Error).self) {
        // 'U' is excluded from the Crockford alphabet
        _ = try Base32Grouped.decode("UUUUU-UUUUU")
    }
    #expect(throws: (any Error).self) {
        _ = try Base32Grouped.decode("!!!!!")
    }
}
