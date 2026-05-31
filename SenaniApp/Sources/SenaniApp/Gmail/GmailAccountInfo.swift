import Foundation
import SenaniGmail

public struct GmailAccountInfo: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding) {
        self.http = http
        self.tokenProvider = tokenProvider
    }

    public func fetchEmail() async throws -> String {
        let token = try await tokenProvider.validAccessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await http.send(request)
        guard response.statusCode < 300 else {
            throw HTTPClientError.unexpectedStatus(
                response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        return try JSONDecoder().decode(UserInfo.self, from: data).email
    }

    private struct UserInfo: Decodable {
        let email: String
    }
}
