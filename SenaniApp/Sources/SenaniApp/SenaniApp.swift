import SwiftUI

/// App entry point. Builds the live composition root once and injects it into
/// the view tree. The single @main App is the executable target's entry point.
@main
struct SenaniApp: App {
    /// The outcome of building the live composition root at launch. On failure
    /// we deliberately do NOT fall back to the preview graph: a preview graph
    /// runs on in-memory FAKE data (seeded deals, FakeTextGenerator) and would
    /// masquerade as a working app while silently discarding the user's work on
    /// quit. Instead we surface the failure so the user knows the data store
    /// could not be opened. preview() stays reserved for #Preview/tests.
    @StateObject private var startup = StartupModel()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        WindowGroup {
            Group {
                switch startup.state {
                case .ready(let environment):
                    RootScene()
                        .environmentObject(environment)
                case .failed(let error):
                    ErrorScene(error: error)
                }
            }
            .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CheckForUpdatesCommand(updateController: updateController)
        }
    }
}

/// Holds the result of the one-time composition-root build. Kept as a small
/// @MainActor object so the @main App can branch between the working UI and a
/// dedicated error scene without ever standing up the preview graph.
@MainActor
final class StartupModel: ObservableObject {
    enum State {
        case ready(AppEnvironment)
        case failed(Error)
    }

    let state: State

    init() {
        // Composition Root: construct the live graph once. If it fails (e.g. the
        // database cannot be opened) surface the error instead of booting a fake
        // in-memory app on preview data.
        do {
            state = .ready(try AppEnvironment.live())
        } catch {
            state = .failed(error)
        }
    }
}
