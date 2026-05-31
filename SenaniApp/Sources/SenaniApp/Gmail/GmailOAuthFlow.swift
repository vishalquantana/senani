import Foundation
import SenaniGmail

public enum GmailOAuthError: Error, Equatable {
    case stateMismatch
    case userDenied(String)
    case missingCode
}

public struct GmailOAuthFlow: Sendable {
    private let auth: GmailAuth
    private let clientID: String
    private let http: any HTTPClient
    private let browser: any BrowserOpening
    private let makeLoopback: @Sendable () throws -> any LoopbackCapturing
    private let makeState: @Sendable () -> String
    private let makePKCE: @Sendable () -> PKCE

    public init(
        auth: GmailAuth,
        clientID: String,
        http: any HTTPClient,
        browser: any BrowserOpening,
        makeLoopback: @escaping @Sendable () throws -> any LoopbackCapturing,
        makeState: @escaping @Sendable () -> String = { UUID().uuidString },
        makePKCE: @escaping @Sendable () -> PKCE = { PKCE.random() }
    ) {
        self.auth = auth
        self.clientID = clientID
        self.http = http
        self.browser = browser
        self.makeLoopback = makeLoopback
        self.makeState = makeState
        self.makePKCE = makePKCE
    }

    public static func consentURL(clientID: String, port: Int, pkce: PKCE, state: String) -> URL {
        GmailAuth.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI(port: port),
            scopes: GmailOAuthConfig.scopes,
            pkce: pkce,
            state: state
        )
    }

    public static func redirectURI(port: Int) -> String {
        "http://127.0.0.1:\(port)/oauth2redirect"
    }

    public func connect() async throws -> String {
        let pkce = makePKCE()
        let state = makeState()
        let loopback = try makeLoopback()
        defer { loopback.stop() }

        let redirectURI = Self.redirectURI(port: loopback.boundPort())
        let url = GmailAuth.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: GmailOAuthConfig.scopes,
            pkce: pkce,
            state: state
        )
        browser.open(url)

        let redirect = try await loopback.awaitRedirect()
        if let error = redirect.error {
            throw GmailOAuthError.userDenied(error)
        }
        guard redirect.state == state else {
            throw GmailOAuthError.stateMismatch
        }
        guard let code = redirect.code else {
            throw GmailOAuthError.missingCode
        }

        try await auth.authenticate(code: code, redirectURI: redirectURI, verifier: pkce.verifier)
        return try await GmailAccountInfo(http: http, tokenProvider: auth).fetchEmail()
    }
}
