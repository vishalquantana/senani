import SwiftUI

/// Adds a single "Check for Updates…" item to the app menu, bound to the
/// shared UpdateController. Disabled while Sparkle is mid-check or unavailable.
struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updateController: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
        }
    }
}
