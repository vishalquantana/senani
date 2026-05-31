import Foundation
import CryptoKit
@testable import SenaniLicensing

/// Mirrors what the offline Scripts/sign_license.swift does, but with an IN-TEST
/// keypair so no real private key is ever committed. Produces a grouped license key.
enum SignerHelper {
    static let formatTag: UInt8 = 0x01   // Ed25519 / v1 — MUST match LicenseVerifier.formatTag

    /// Sign a payload with `privateKey`, return the grouped XXXXX-XXXXX key string.
    static func makeKey(_ payload: LicensePayload,
                        signedBy privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payloadBytes = try payload.canonicalBytes()
        var signed = Data([formatTag])
        signed.append(payloadBytes)
        let signature = try privateKey.signature(for: signed)   // signs tag ‖ payload
        var keyBytes = signed
        keyBytes.append(signature)                              // tag ‖ payload ‖ sig(64)
        return Base32Grouped.encode(keyBytes)
    }
}
