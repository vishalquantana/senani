import Foundation

/// The result of verifying a license key, fully offline.
/// - \`.valid(tier)\`  : signature checks out against the embedded public key.
/// - \`.invalid\`      : structurally a key, but signed by a DIFFERENT private key.
/// - \`.tampered\`     : structurally a key, payload bytes were altered after signing.
/// - \`.malformed\`    : not decodable as a key at all (bad base32, wrong length, bad JSON).
public enum LicenseStatus: Sendable, Equatable {
    case valid(LicenseTier)
    case invalid
    case tampered
    case malformed

    /// The tier if and only if the key is valid; nil otherwise. Convenience for gating.
    public var tier: LicenseTier? {
        if case .valid(let t) = self { return t }
        return nil
    }
}
