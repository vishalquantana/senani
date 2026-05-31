import Testing
import Foundation
import CryptoKit
@testable import SenaniLicensing

@Test func statusEquatableDistinguishesTiers() {
    #expect(LicenseStatus.valid(.core) == .valid(.core))
    #expect(LicenseStatus.valid(.core) != .valid(.pro))
    #expect(LicenseStatus.invalid != .tampered)
    #expect(LicenseStatus.malformed != .invalid)
}

private func corePayload() -> LicensePayload {
    LicensePayload(licenseID: "LIC-CORE", tier: .core,
                   issued: Date(timeIntervalSince1970: 1_700_000_000))
}
private func proPayload() -> LicensePayload {
    LicensePayload(licenseID: "LIC-PRO", tier: .pro,
                   issued: Date(timeIntervalSince1970: 1_700_000_000),
                   buyerEmail: "buyer@example.com", seats: 1)
}

@Test func validKeyVerifiesWithCorrectTier() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    let coreKey = try SignerHelper.makeKey(corePayload(), signedBy: priv)
    #expect(verifier.verify(coreKey) == .valid(.core))

    let proKey = try SignerHelper.makeKey(proPayload(), signedBy: priv)
    #expect(verifier.verify(proKey) == .valid(.pro))
}

@Test func wrongKeySignatureIsInvalid() throws {
    let sellerKey = Curve25519.Signing.PrivateKey()
    let attackerKey = Curve25519.Signing.PrivateKey()   // a DIFFERENT private key
    let verifier = LicenseVerifier(publicKey: sellerKey.publicKey)

    let forged = try SignerHelper.makeKey(proPayload(), signedBy: attackerKey)
    #expect(verifier.verify(forged) == .invalid)
}

@Test func tamperedPayloadIsTampered() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    // Sign a CORE key, then add a space to the payload bytes while keeping the
    // original signature → structure is intact, but payload is non-canonical.
    let coreKey = try SignerHelper.makeKey(corePayload(), signedBy: priv)
    var bytes = try Base32Grouped.decode(coreKey)
    // Find the first '{' and replace with '{ ' (add a space)
    if let range = bytes.range(of: Data("{".utf8)) {
        bytes.replaceSubrange(range, with: Data("{ ".utf8))
    }
    let tamperedKey = Base32Grouped.encode(bytes)
    #expect(verifier.verify(tamperedKey) == .tampered)
}

@Test func garbageStringIsMalformed() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    #expect(verifier.verify("not-a-key") == .malformed)        // illegal base32 chars
    #expect(verifier.verify("") == .malformed)                 // empty
    #expect(verifier.verify("AAAAA-AAAAA") == .malformed)      // decodes but far too short
}
