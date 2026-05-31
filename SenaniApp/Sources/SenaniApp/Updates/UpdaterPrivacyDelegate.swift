#if canImport(Sparkle)
import Foundation
import Sparkle

/// Belt-and-suspenders privacy: even if Info.plist were misconfigured, this
/// delegate guarantees Sparkle posts NO system-profile data to the feed host.
final class UpdaterPrivacyDelegate: NSObject, SPUUpdaterDelegate {
    /// Returning an empty array means Sparkle appends no profile parameters to
    /// the feed request. (Combined with SUEnableSystemProfiling = NO.)
    func feedParameters(for updater: SPUUpdater,
                        sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        return []
    }

    /// Refuse profiling regardless of caller.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
}
#endif
