import CryptoKit
import Foundation

public struct PKCE: Sendable, Equatable {
    public let verifier: String

    public init(verifier: String) {
        self.verifier = verifier
    }

    public static func random() -> PKCE {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let verifier = String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        return PKCE(verifier: verifier)
    }

    public var challenge: String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return MIMEBuilder.base64URL(Data(digest))
    }
}

public enum GmailAuthError: Error, Equatable {
    case notAuthenticated
    case missingAuthorizationCode
    case stateMismatch
}

public protocol AccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
}

public actor GmailAuth: AccessTokenProviding {
    private let clientID: String
    private let http: any HTTPClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date

    public init(
        clientID: String,
        http: any HTTPClient,
        store: any TokenStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientID = clientID
        self.http = http
        self.store = store
        self.now = now
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        scopes: [String],
        pkce: PKCE,
        state: String
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    public static func tokenExchangeRequest(
        clientID: String,
        code: String,
        redirectURI: String,
        verifier: String
    ) -> URLRequest {
        formRequest(parameters: [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
    }

    public static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formRequest(parameters: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    public func validAccessToken() async throws -> String {
        guard let current = try await store.load() else {
            throw GmailAuthError.notAuthenticated
        }
        let date = now()
        guard current.needsRefresh(now: date, skew: 60) else {
            return current.accessToken
        }

        let request = Self.refreshRequest(clientID: clientID, refreshToken: current.refreshToken)
        let (data, response) = try await http.send(request)
        try Self.validate(response: response, data: data)
        let refreshed = try JSONDecoder().decode(TokenResponse.self, from: data)
        let next = OAuthToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? current.refreshToken,
            expiresAt: date.addingTimeInterval(TimeInterval(refreshed.expiresIn))
        )
        try await store.save(next)
        return next.accessToken
    }

    public func authenticate(code: String, redirectURI: String, verifier: String) async throws {
        let request = Self.tokenExchangeRequest(
            clientID: clientID,
            code: code,
            redirectURI: redirectURI,
            verifier: verifier
        )
        let (data, response) = try await http.send(request)
        try Self.validate(response: response, data: data)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refreshToken = token.refreshToken ?? ""
        guard !refreshToken.isEmpty else {
            throw GmailAuthError.notAuthenticated
        }
        try await store.save(OAuthToken(
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn))
        ))
    }

    static func validate(response: HTTPURLResponse, data: Data) throws {
        guard response.statusCode < 300 else {
            throw HTTPClientError.unexpectedStatus(
                response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }

    private static func formRequest(parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
