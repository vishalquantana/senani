import Testing
@testable import SenaniApp

struct SemanticVersionTests {
    @Test func parsesDottedComponents() throws {
        let v = try #require(SemanticVersion("1.4.2"))
        #expect(v.components == [1, 4, 2])
    }

    @Test func equalWhenTrailingZeros() throws {
        let a = try #require(SemanticVersion("1.4"))
        let b = try #require(SemanticVersion("1.4.0"))
        #expect(a == b)
    }

    @Test func ordersNumerically() throws {
        let older = try #require(SemanticVersion("1.9.0"))
        let newer = try #require(SemanticVersion("1.10.0"))   // 10 > 9, not string order
        #expect(older < newer)
    }

    @Test func rejectsEmptyOrNonNumeric() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("1.x.0") == nil)
    }
}
