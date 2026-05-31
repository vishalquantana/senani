import Foundation
import Testing
@testable import SenaniApp

@Test func gmailOAuthScopesIncludeReadModifyComposeAndIdentity() {
    let scopes = GmailOAuthConfig.scopes
    #expect(scopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
    #expect(scopes.contains("https://www.googleapis.com/auth/gmail.modify"))
    #expect(scopes.contains("https://www.googleapis.com/auth/gmail.compose"))
    #expect(scopes.contains("openid"))
    #expect(scopes.contains("email"))
}

@Test func gmailOAuthResolvesClientIDFromEnvironmentFirst() throws {
    let id = try GmailOAuthConfig.clientID(
        environment: ["SENANI_GMAIL_CLIENT_ID": "ENV.apps.googleusercontent.com"],
        infoPlistValue: "PLIST.apps.googleusercontent.com",
        fileValue: { "FILE.apps.googleusercontent.com" }
    )
    #expect(id == "ENV.apps.googleusercontent.com")
}

@Test func gmailOAuthFallsBackToInfoPlistThenFile() throws {
    let fromPlist = try GmailOAuthConfig.clientID(
        environment: [:],
        infoPlistValue: "PLIST.apps.googleusercontent.com",
        fileValue: { nil }
    )
    #expect(fromPlist == "PLIST.apps.googleusercontent.com")

    let fromFile = try GmailOAuthConfig.clientID(
        environment: [:],
        infoPlistValue: nil,
        fileValue: { "FILE.apps.googleusercontent.com" }
    )
    #expect(fromFile == "FILE.apps.googleusercontent.com")
}

@Test func gmailOAuthThrowsWhenNoClientIDAnywhere() {
    #expect(throws: GmailOAuthConfigError.self) {
        _ = try GmailOAuthConfig.clientID(
            environment: [:],
            infoPlistValue: nil,
            fileValue: { nil }
        )
    }
}
