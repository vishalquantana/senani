import Foundation
import CryptoKit

/// Verifies one-time license keys FULLY OFFLINE. Holds ONLY the Ed25519 public
/// key — the private key lives solely on the seller's offline machine. No network,
/// no accounts, no telemetry.
///
/// Key byte layout (before base32 grouping):
///   [0]        formatTag (0x01 = Ed25519 / v1)
///   [1 ..< n]  canonical payload JSON bytes
///   [n ..< n+64] Ed25519 signature over bytes[0 ..< n] (i.e. tag ‖ payload)
public struct LicenseVerifier: Sendable {
    static let formatTag: UInt8 = 0x01
    static let signatureLength = 64

    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    public func verify(_ key: String) -> LicenseStatus {
        // 1. Decode grouped base32. Any failure → not a key at all.
        guard let raw = try? Base32Grouped.decode(key) else { return .malformed }

        // 2. Structural minimum: tag(1) + at least 1 payload byte + signature(64).
        guard raw.count > 1 + Self.signatureLength, raw.first == Self.formatTag else {
            return .malformed
        }

        // 3. Split: signed region (tag ‖ payload) and the trailing 64-byte signature.
        let signedRegion = raw.prefix(raw.count - Self.signatureLength)   // tag ‖ payload
        let signature = raw.suffix(Self.signatureLength)
        let payloadBytes = signedRegion.dropFirst()                       // strip tag

        // 4. The payload JSON must parse, else the bytes aren't a real key → malformed.
        guard let payload = try? LicensePayload(canonicalBytes: Data(payloadBytes)) else {
            return .malformed
        }

        // 5. Verify the Ed25519 signature over the EXACT signed region with the
        //    embedded public key. A correct signature from the trusted key → valid.
        if publicKey.isValidSignature(Data(signature), for: Data(signedRegion)) {
            return .valid(payload.tier)
        }

        // 6. Signature failed but the key is structurally a real, parseable license.
        //    Re-derive the canonical bytes the payload SHOULD have produced: if they
        //    differ from the presented payload bytes, the payload was altered after
        //    signing → tampered. If they MATCH (payload intact, but the signature
        //    simply doesn't verify against our key), it was signed by another key
        //    → invalid (a forgery with a foreign key).
        let recanonical = (try? payload.canonicalBytes()) ?? Data()
        return recanonical == Data(payloadBytes) ? .invalid : .tampered
    }
}
