import Testing
import Foundation
@testable import SenaniRules

@Suite struct ConditionTests {
    private func msg(
        from: String = "bob@vendor.com", subject: String = "Invoice 42",
        body: String = "Payment due", hasAttachment: Bool = true,
        unsub: String? = nil, labels: [String] = [], thread: String = "t1",
        ageSeconds: TimeInterval = 0
    ) -> Message {
        Message(
            id: "m", from: from, to: ["me@acme.io"], subject: subject, body: body,
            hasAttachment: hasAttachment, listUnsubscribeHeader: unsub, labels: labels,
            threadId: thread, date: Date(timeIntervalSince1970: 1000 - ageSeconds),
            isFromUser: false
        )
    }
    private let now = Date(timeIntervalSince1970: 1000)

    @Test func structuredConditionsEvaluateIndividually() {
        let m = msg()
        #expect(StructuredCondition.from("bob@vendor.com").matches(m, now: now))
        #expect(StructuredCondition.domain("vendor.com").matches(m, now: now))
        #expect(StructuredCondition.subjectContains("invoice").matches(m, now: now)) // case-insensitive
        #expect(StructuredCondition.bodyContains("due").matches(m, now: now))
        #expect(StructuredCondition.hasAttachment.matches(m, now: now))
        #expect(StructuredCondition.isInThread("t1").matches(m, now: now))
        #expect(!StructuredCondition.hasLabel("Finance").matches(m, now: now))
        #expect(StructuredCondition.hasLabel("Finance").matches(msg(labels: ["Finance"]), now: now))
        #expect(StructuredCondition.listUnsubscribeHeader.matches(msg(unsub: "<mailto:x>"), now: now))
        #expect(!StructuredCondition.listUnsubscribeHeader.matches(m, now: now))
    }

    @Test func olderThanComparesAgainstNow() {
        #expect(StructuredCondition.olderThan(60).matches(msg(ageSeconds: 120), now: now))
        #expect(!StructuredCondition.olderThan(60).matches(msg(ageSeconds: 30), now: now))
    }

    @Test func olderThanIsExclusiveAtBoundary() {
        // A message exactly `secs` old is NOT older-than (exclusive `>`).
        #expect(!StructuredCondition.olderThan(60).matches(msg(ageSeconds: 60), now: now))
    }

    @Test func matchModeAllRequiresEveryCondition() {
        let c = Conditions(mode: .all,
            structured: [.domain("vendor.com"), .hasAttachment], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now))
        #expect(!c.matchesStructured(msg(hasAttachment: false), now: now))
    }

    @Test func matchModeAnyRequiresAtLeastOne() {
        let c = Conditions(mode: .any,
            structured: [.domain("nope.com"), .hasAttachment], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now)) // hasAttachment true -> at least one matches
        #expect(!c.matchesStructured(msg(from: "x@other.com", hasAttachment: false), now: now)) // none match
    }

    @Test func matchModeNoneRequiresNoConditionTrue() {
        let c = Conditions(mode: .none,
            structured: [.domain("spam.com")], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now))
        #expect(!c.matchesStructured(msg(from: "x@spam.com"), now: now))
    }

    @Test func emptyStructuredIsVacuouslyTrueUnderAll() {
        let c = Conditions(mode: .all, structured: [], aiPredicate: "is about pricing")
        #expect(c.matchesStructured(msg(), now: now)) // lets a pure-AI rule reach its predicate
    }

    @Test func emptyStructuredSemanticsUnderAnyAndNone() {
        // `.any` over an empty set: no condition matches -> false.
        let anyEmpty = Conditions(mode: .any, structured: [], aiPredicate: nil)
        #expect(!anyEmpty.matchesStructured(msg(), now: now))
        // `.none` over an empty set: no condition matches -> true.
        let noneEmpty = Conditions(mode: .none, structured: [], aiPredicate: nil)
        #expect(noneEmpty.matchesStructured(msg(), now: now))
    }
}
