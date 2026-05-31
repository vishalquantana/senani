import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

@MainActor
@Test func gmailAccountConnectTransitionsToConnectedWithEmail() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    await http.enqueueJSON(
        #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!
    )
    await http.enqueueJSON(
        #"{"email":"ramesh@quantana.in"}"#,
        url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    )
    let auth = GmailAuth(
        clientID: "CID",
        http: http,
        store: store,
        now: { Date(timeIntervalSince1970: 1_000_000) }
    )
    let capture = FakeLoopbackCapture(
        port: 49152,
        result: LoopbackResult(code: "C", state: "S", error: nil)
    )
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: FakeBrowserOpener(),
        makeLoopback: { capture },
        makeState: { "S" },
        makePKCE: { PKCE(verifier: "verifier-123") }
    )
    let account = GmailAccount(store: store, flow: flow)

    #expect(account.state == .disconnected)
    await account.connect()

    #expect(account.state == .connected(email: "ramesh@quantana.in"))
}

@MainActor
@Test func gmailAccountDisconnectClearsTokenAndState() async throws {
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(
        accessToken: "AT",
        refreshToken: "RT",
        expiresAt: Date(timeIntervalSince1970: 9_999_999_999)
    ))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: FakeBrowserOpener(),
        makeLoopback: {
            FakeLoopbackCapture(port: 1, result: LoopbackResult(code: nil, state: nil, error: nil))
        }
    )
    let account = GmailAccount(store: store, flow: flow)

    await account.disconnect()

    #expect(account.state == .disconnected)
    #expect(try await store.load() == nil)
}

@MainActor
@Test func gmailAccountRefreshFromStoreReflectsExistingToken() async throws {
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(
        accessToken: "AT",
        refreshToken: "RT",
        expiresAt: Date(timeIntervalSince1970: 9_999_999_999)
    ))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: FakeBrowserOpener(),
        makeLoopback: {
            FakeLoopbackCapture(port: 1, result: LoopbackResult(code: nil, state: nil, error: nil))
        }
    )
    let account = GmailAccount(store: store, flow: flow)

    await account.refreshFromStore()

    #expect(account.isConnected)
}
