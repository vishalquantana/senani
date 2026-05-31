#if canImport(Sparkle)
import Foundation
import Sparkle
import Combine

/// @MainActor wrapper around Sparkle's standard updater. The "Check for
/// Updates…" menu binds to this. Profiling is forced off via the delegate;
/// automatic checks remain user opt-in.
@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private let privacyDelegate = UpdaterPrivacyDelegate()

    /// `canCheckForUpdates` drives the menu item's enabled state.
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: privacyDelegate,
            userDriverDelegate: nil
        )
        // Enforce privacy in code (do not rely on plist alone).
        controller.updater.sendsSystemProfile = false
        // Honor opt-in: do not flip automaticallyChecksForUpdates to true here.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#else
import Foundation
/// Headless / no-Sparkle fallback so the package type-checks on runners without
/// the framework (e.g. CI running `swift test`). The menu item is disabled.
@MainActor
final class UpdateController: ObservableObject {
    @Published var canCheckForUpdates = false
    init() {}
    func checkForUpdates() {}
}
#endif
