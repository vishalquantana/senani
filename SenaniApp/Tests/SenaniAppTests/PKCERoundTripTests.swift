import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

@Test func pkceVerifierAndChallengeRoundTrip() {
    let pkce = PKCE.random()

    #expect(pkce.verifier.count == 64)
    #expect(!pkce.challenge.contains("="))
    #expect(!pkce.challenge.contains("+"))
    #expect(!pkce.challenge.contains("/"))
    #expect(PKCE(verifier: pkce.verifier).challenge == pkce.challenge)
    #expect(PKCE.random().verifier != pkce.verifier)
}
