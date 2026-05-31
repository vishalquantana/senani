import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

@Test func consentURLContainsScopesChallengeAndLoopbackRedirect() throws {
    let pkce = PKCE(verifier: "verifier-123")
    let url = GmailOAuthFlow.consentURL(
        clientID: "CID.apps.googleusercontent.com",
        port: 49152,
        pkce: pkce,
        state: "STATE"
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "accounts.google.com")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    #expect(query["client_id"] == "CID.apps.googleusercontent.com")
    #expect(query["redirect_uri"] == "http://127.0.0.1:49152/oauth2redirect")
    #expect(query["code_challenge"] == pkce.challenge)
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["state"] == "STATE")
    #expect(query["access_type"] == "offline")
    let scope = query["scope"] ?? ""
    #expect(scope.contains("gmail.readonly"))
    #expect(scope.contains("gmail.modify"))
    #expect(scope.contains("gmail.compose"))
}
