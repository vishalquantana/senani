import Foundation
import CryptoKit

/// The app's embedded Ed25519 PUBLIC key (base64 of the 32-byte raw representation).
/// The PRIVATE key NEVER appears here or anywhere in the repo — it lives only on the
/// seller's offline machine. Replace this base64 with the output of:
///     swift Scripts/sign_license.swift gen-key
/// (the script prints the public-key base64 to embed and writes the private key to a
/// file you keep OFFLINE — see Scripts/README-licensing.md).
public enum EmbeddedPublicKey {
    /// PLACEHOLDER: a base64-encoded 32-byte all-zero key. The app loads/verifies
    /// against it without crashing, but every real key reports `.invalid` until the
    /// human embeds the production public key. Tests use their own in-test keypair,
    /// so this placeholder never blocks the suite.
    public static let base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    enum KeyError: Error { case badEncoding, wrongLength }

    public static func publicKey() throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64) else { throw KeyError.badEncoding }
        guard data.count == 32 else { throw KeyError.wrongLength }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}

public extension LicenseVerifier {
    /// The production verifier using the embedded public key.
    static func senani() throws -> LicenseVerifier {
        LicenseVerifier(publicKey: try EmbeddedPublicKey.publicKey())
    }
}
