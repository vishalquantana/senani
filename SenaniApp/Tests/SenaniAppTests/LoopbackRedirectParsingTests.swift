import Foundation
import Testing
@testable import SenaniApp

@Test func parsesCodeAndStateFromRequestLine() {
    let result = LoopbackRedirectParser.parse(
        requestLine: "GET /oauth2redirect?code=AUTH123&state=STATE456 HTTP/1.1"
    )
    #expect(result.code == "AUTH123")
    #expect(result.state == "STATE456")
    #expect(result.error == nil)
}

@Test func parsesErrorWhenUserDenies() {
    let result = LoopbackRedirectParser.parse(
        requestLine: "GET /oauth2redirect?error=access_denied&state=STATE456 HTTP/1.1"
    )
    #expect(result.error == "access_denied")
    #expect(result.code == nil)
}

@Test func percentDecodesQueryValues() {
    let result = LoopbackRedirectParser.parse(
        requestLine: "GET /oauth2redirect?code=a%2Fb%2Bc&state=x HTTP/1.1"
    )
    #expect(result.code == "a/b+c")
    #expect(result.state == "x")
}

@Test func missingQueryYieldsAllNil() {
    let result = LoopbackRedirectParser.parse(requestLine: "GET / HTTP/1.1")
    #expect(result.code == nil)
    #expect(result.state == nil)
    #expect(result.error == nil)
}

@Test func liveBrowserOpenerConformsToProtocol() {
    #if canImport(AppKit)
    let _: any BrowserOpening = NSWorkspaceBrowserOpener()
    #endif
}
