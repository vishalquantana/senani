import Testing
@testable import SenaniEngine

@Suite struct ListUnsubscribeParserTests {
    @Test func parsesBothMailtoAndHttps() {
        let p = ListUnsubscribeParser.parse("<mailto:unsubscribe@brand.com?subject=unsub>, <https://brand.com/u/abc123>")
        #expect(p.mailto == "unsubscribe@brand.com")          // query stripped
        #expect(p.https == "https://brand.com/u/abc123")
    }

    @Test func parsesMailtoOnly() {
        let p = ListUnsubscribeParser.parse("<mailto:bye@list.example.com>")
        #expect(p.mailto == "bye@list.example.com")
        #expect(p.https == nil)
    }

    @Test func parsesHttpsOnly() {
        let p = ListUnsubscribeParser.parse("<https://x.io/unsub?id=9>")
        #expect(p.mailto == nil)
        #expect(p.https == "https://x.io/unsub?id=9")
    }

    @Test func toleratesHttpAndWhitespaceAndNoBrackets() {
        let p = ListUnsubscribeParser.parse("  mailto:a@b.com ,  http://b.com/u  ")
        #expect(p.mailto == "a@b.com")
        #expect(p.https == "http://b.com/u")    // http accepted too
    }

    @Test func picksFirstOfEachScheme() {
        let p = ListUnsubscribeParser.parse("<mailto:first@b.com>, <mailto:second@b.com>, <https://one.example/u>, <https://two.example/u>")
        #expect(p.mailto == "first@b.com")
        #expect(p.https == "https://one.example/u")
    }

    @Test func emptyAndGarbageReturnNil() {
        #expect(ListUnsubscribeParser.parse("").mailto == nil)
        #expect(ListUnsubscribeParser.parse("").https == nil)
        let g = ListUnsubscribeParser.parse("<<>> not a uri ;;;")
        #expect(g.mailto == nil)
        #expect(g.https == nil)
    }

    @Test func hasAnyReflectsPresence() {
        #expect(ListUnsubscribeParser.parse("<mailto:a@b.com>").hasAny == true)
        #expect(ListUnsubscribeParser.parse("garbage").hasAny == false)
    }
}
