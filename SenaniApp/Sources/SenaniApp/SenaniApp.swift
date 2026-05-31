import SwiftUI

/// App entry point. Builds the live composition root once and injects it into
/// the view tree. The single @main App is the executable target's entry point.
@main
struct SenaniApp: App {
    @StateObject private var environment: AppEnvironment
    @StateObject private var updateController = UpdateController()

    init() {
        // Composition Root: construct the live graph once. If it fails (e.g. the
        // database cannot be opened), fall back to an in-memory preview graph.
        let env: AppEnvironment
        do {
            env = try AppEnvironment.live()
        } catch {
            env = AppEnvironment.preview()
        }
        _environment = StateObject(wrappedValue: env)
    }

    var body: some Scene {
        WindowGroup {
            RootScene()
                .environmentObject(environment)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CheckForUpdatesCommand(updateController: updateController)
        }
    }
}
