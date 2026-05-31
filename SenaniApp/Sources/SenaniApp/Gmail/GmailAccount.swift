import Foundation
import Combine
import SenaniGmail

@MainActor
public final class GmailAccount: ObservableObject {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(email: String)
        case failed(message: String)
    }

    @Published public private(set) var state: State = .disconnected

    private let store: any TokenStore
    private let flow: GmailOAuthFlow

    public init(store: any TokenStore, flow: GmailOAuthFlow) {
        self.store = store
        self.flow = flow
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    public func refreshFromStore() async {
        if (try? await store.load()) != nil {
            if case .connected = state {
                return
            }
            state = .connected(email: "")
        } else {
            state = .disconnected
        }
    }

    public func connect() async {
        state = .connecting
        do {
            let email = try await flow.connect()
            state = .connected(email: email)
        } catch {
            state = .failed(message: Self.describe(error))
        }
    }

    public func disconnect() async {
        try? await store.clear()
        state = .disconnected
    }

    private static func describe(_ error: Error) -> String {
        if let oauth = error as? GmailOAuthError {
            switch oauth {
            case .stateMismatch:
                return "Sign-in could not be verified. Please try again."
            case .userDenied:
                return "Access was not granted."
            case .missingCode:
                return "No authorization code was returned."
            }
        }

        if let auth = error as? GmailAuthError, auth == .notAuthenticated {
            return "Google did not return a refresh token. Please try again and grant offline access."
        }

        return "Could not connect to Gmail: \(error)"
    }
}
