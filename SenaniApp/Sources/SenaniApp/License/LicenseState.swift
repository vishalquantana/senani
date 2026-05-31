import Foundation
import SwiftUI
import SenaniLicensing

/// App-tier adapter binding the Keychain-stored key to the offline verifier and
/// exposing tier-based gating to the composition root and UI. The ONLY place the
/// app touches licensing. No network.
@MainActor
public final class LicenseState: ObservableObject {
    @Published public private(set) var status: LicenseStatus

    private let verifier: LicenseVerifier
    private let store: LicenseKeychainStore

    /// Test/preview seam: inject a status directly.
    public init(status: LicenseStatus) {
        self.status = status
        self.verifier = (try? LicenseVerifier.senani()) ?? LicenseVerifier(
            publicKey: (try? EmbeddedPublicKey.publicKey())!)
        self.store = LicenseKeychainStore()
    }

    /// Live: verify whatever key is stored in the Keychain (offline).
    public init(verifier: LicenseVerifier? = nil, store: LicenseKeychainStore = .init()) {
        self.verifier = verifier ?? ((try? LicenseVerifier.senani())
            ?? LicenseVerifier(publicKey: (try? EmbeddedPublicKey.publicKey())!))
        self.store = store
        if let stored = try? store.load() {
            self.status = self.verifier.verify(stored)
        } else {
            self.status = .invalid   // unlicensed
        }
    }

    public var tier: LicenseTier? { status.tier }

    /// Activate a typed key: verify offline; persist only if valid.
    public func activate(_ key: String) {
        let result = verifier.verify(key)
        status = result
        if result.tier != nil { try? store.save(key) }
    }

    public func deactivate() {
        try? store.clear()
        status = .invalid
    }

    public func unlocks(_ feature: Feature) -> Bool {
        guard let tier else { return false }
        return tier.unlocks(feature)
    }

    /// Whether an agent (by stable id) is enabled under the current tier. Unknown
    /// ids default to disabled (fail-closed).
    public func enablesAgent(id: String) -> Bool {
        guard let feature = Feature(agentID: id) else { return false }
        return unlocks(feature)
    }
}
