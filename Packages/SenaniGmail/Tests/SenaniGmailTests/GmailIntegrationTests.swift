import Foundation
import Testing
@testable import SenaniGmail

private struct LiveCreds {
    let clientID: String
    let refreshToken: String
    let email: String

    static var fromEnv: LiveCreds? {
        let env = ProcessInfo.processInfo.environment
        guard let clientID = env["SENANI_GMAIL_CLIENT_ID"],
              let refreshToken = env["SENANI_GMAIL_REFRESH_TOKEN"],
              let email = env["SENANI_GMAIL_TEST_EMAIL"]
        else {
            return nil
        }
        return LiveCreds(clientID: clientID, refreshToken: refreshToken, email: email)
    }
}

@Test(.enabled(if: LiveCreds.fromEnv != nil))
func liveRefreshAndListAgainstRealGmail() async throws {
    let creds = try #require(LiveCreds.fromEnv)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(
        accessToken: "expired",
        refreshToken: creds.refreshToken,
        expiresAt: Date(timeIntervalSince1970: 0)
    ))
    let auth = GmailAuth(clientID: creds.clientID, http: URLSessionHTTPClient(), store: store)
    let token = try await auth.validAccessToken()
    #expect(!token.isEmpty)

    let sync = GmailSync(http: URLSessionHTTPClient(), tokenProvider: auth, accountEmail: creds.email)
    let messages = try await sync.fetchMessages(query: "in:inbox", maxResults: 3)
    #expect(messages.count <= 3)
}
