import Foundation

/// Single source of truth for Sparkle settings. The same values appear in the
/// app's Info.plist (consumed by Sparkle at runtime) and here (used to assert /
/// override at startup). PRIVACY: profiling is OFF and automatic checks are
/// opt-in, per docs/ARCHITECTURE.md (no telemetry, no accounts).
public enum UpdateConfiguration {
    /// Human input: real value supplied at package time. Placeholder until then.
    public static let feedURL = "https://updates.example.invalid/appcast.xml"

    /// Human input: base64 EdDSA public key from `generate_keys`. Placeholder.
    public static let publicEDKey = "REPLACE_WITH_SUPublicEDKey_FROM_generate_keys"

    /// PRIVACY FLAGS — must match Info.plist and are re-enforced in code.
    public static let systemProfilingEnabled = false      // SUEnableSystemProfiling = NO
    public static let automaticChecksOptIn   = false      // user opts in; not forced YES
    public static let sendsAnonymousMetrics  = false      // never
}
