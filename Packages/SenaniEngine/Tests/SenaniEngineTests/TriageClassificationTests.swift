import Testing
@testable import SenaniEngine
import SenaniInference
import Foundation

@Test func categoryAndPriorityLabelStrings() {
    #expect(TriageCategory.lead.label == "Senani/Category/Lead")
    #expect(TriageCategory.booking.label == "Senani/Category/Booking")
    #expect(TriageCategory.proposal.label == "Senani/Category/Proposal")
    #expect(TriageCategory.newsletter.label == "Senani/Category/Newsletter")
    #expect(TriageCategory.personal.label == "Senani/Category/Personal")
    #expect(TriageCategory.other.label == "Senani/Category/Other")
    #expect(TriagePriority.high.label == "Senani/Priority/High")
    #expect(TriagePriority.normal.label == "Senani/Priority/Normal")
    #expect(TriagePriority.low.label == "Senani/Priority/Low")
}

@Test func schemaConstrainsTheShapeToCategoryPriorityReason() {
    guard case let .object(properties, required) = TriageClassification.schema else {
        Issue.record("schema must be an object"); return
    }
    #expect(properties["category"] == .string)
    #expect(properties["priority"] == .string)
    #expect(properties["reason"] == .string)
    #expect(Set(required) == ["category", "priority", "reason"])
    #expect(TriageClassification.schema == JSONSchema(json: TriageClassification.schemaJSON))
}

@Test func parsesWellFormedClassification() {
    let c = TriageClassification.parse(#"{"category":"Lead","priority":"high","reason":"new prospect"}"#)
    #expect(c.category == .lead)
    #expect(c.priority == .high)
    #expect(c.reason == "new prospect")
}

@Test func parseToleratesSurroundingProseAndCasing() {
    let c = TriageClassification.parse(#"Sure! {"category":"BOOKING","priority":"Low","reason":"reschedule"} done"#)
    #expect(c.category == .booking)
    #expect(c.priority == .low)
}

@Test func unknownCategoryFallsBackToOther() {
    let c = TriageClassification.parse(#"{"category":"Spaceship","priority":"high","reason":"?"}"#)
    #expect(c.category == .other)
    #expect(c.priority == .high)
}

@Test func unknownPriorityFallsBackToNormal() {
    let c = TriageClassification.parse(#"{"category":"Lead","priority":"URGENT-NOW","reason":"?"}"#)
    #expect(c.category == .lead)
    #expect(c.priority == .normal)
}

@Test func malformedJsonFallsBackToOtherNormalNeverCrashes() {
    let bad = TriageClassification.parse("{ this is not json")
    #expect(bad.category == .other)
    #expect(bad.priority == .normal)
    let empty = TriageClassification.parse("")
    #expect(empty.category == .other)
    #expect(empty.priority == .normal)
    let missing = TriageClassification.parse(#"{"reason":"only reason"}"#)
    #expect(missing.category == .other)
    #expect(missing.priority == .normal)
}
