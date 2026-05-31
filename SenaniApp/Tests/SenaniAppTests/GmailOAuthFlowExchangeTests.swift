import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

@Test func connectExchangesCodeStoresTokenAndReturnsEmail() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    await http.enqueueJSON(
        #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!
    )
    await http.enqueueJSON(
        #"{"email":"ramesh@quantana.in","email_verified":true}"#,
        url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    )

    let auth = GmailAuth(
        clientID: "CID",
        http: http,
        store: store,
        now: { Date(timeIntervalSince1970: 1_000_000) }
    )
    let browser = FakeBrowserOpener()
    let capture = FakeLoopbackCapture(
        port: 49152,
        result: LoopbackResult(code: "AUTHCODE", state: "EXPECTED_STATE", error: nil)
    )
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: browser,
        makeLoopback: { capture },
        makeState: { "EXPECTED_STATE" },
        makePKCE: { PKCE(verifier: "verifier-123") }
    )

    let email = try await flow.connect()

    #expect(email == "ramesh@quantana.in")
    #expect(browser.opened.count == 1)
    #expect(browser.opened.first?.host == "accounts.google.com")
    let stored = try await store.load()
    #expect(stored?.accessToken == "AT")
    #expect(stored?.refreshToken == "RT")
}

@Test func connectThrowsOnStateMismatch() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let capture = FakeLoopbackCapture(
        port: 49152,
        result: LoopbackResult(code: "C", state: "WRONG", error: nil)
    )
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: FakeBrowserOpener(),
        makeLoopback: { capture },
        makeState: { "EXPECTED" }
    )

    await #expect(throws: GmailOAuthError.self) {
        _ = try await flow.connect()
    }
    #expect(try await store.load() == nil)
}

@Test func connectThrowsWhenUserDenies() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let capture = FakeLoopbackCapture(
        port: 49152,
        result: LoopbackResult(code: nil, state: "S", error: "access_denied")
    )
    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: FakeBrowserOpener(),
        makeLoopback: { capture },
        makeState: { "S" }
    )

    await #expect(throws: GmailOAuthError.self) {
        _ = try await flow.connect()
    }
}
