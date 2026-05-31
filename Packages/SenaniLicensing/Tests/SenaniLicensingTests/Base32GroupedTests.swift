import Testing
import CryptoKit
@testable import SenaniLicensing

@Test func packageImportsCompileAndCryptoKitLinks() {
    // Proves the package builds and CryptoKit (Ed25519) links.
    let key = Curve25519.Signing.PrivateKey()
    #expect(key.publicKey.rawRepresentation.count == 32)
}
