import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

@Test func validAccessTokenRefreshesWhenExpired() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(
        accessToken: "old",
        refreshToken: "RT",
        expiresAt: now.addingTimeInterval(10)
    ))
    let http = FakeHTTPClient()
    await http.enqueueJSON(
        #"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!
    )
    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { now })

    let token = try await auth.validAccessToken()

    #expect(token == "new")
    let stored = try await store.load()
    #expect(stored?.accessToken == "new")
    #expect(stored?.refreshToken == "RT")
}

@Test func validAccessTokenSkipsRefreshWhenFresh() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(
        accessToken: "good",
        refreshToken: "RT",
        expiresAt: now.addingTimeInterval(3_600)
    ))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { now })

    #expect(try await auth.validAccessToken() == "good")
    #expect(await http.recordedRequests.isEmpty)
}
