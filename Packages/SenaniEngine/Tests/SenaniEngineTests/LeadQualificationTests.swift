import Testing
@testable import SenaniEngine
import SenaniInference
import Foundation

@Test func schemaConstrainsShapeToScoreCompanyIntentReason() {
    guard case let .object(properties, required) = LeadQualification.schema else {
        Issue.record("schema must be an object"); return
    }
    #expect(properties["score"] == .number)
    #expect(properties["company"] == .string)
    #expect(properties["intent"] == .string)
    #expect(properties["reason"] == .string)
    #expect(Set(required) == ["score", "company", "intent", "reason"])
    #expect(LeadQualification.schema == JSONSchema(json: LeadQualification.schemaJSON))
}

@Test func parsesWellFormedQualification() {
    let q = LeadQualification.parse(
        #"{"score":82,"company":"Acme Corp","intent":"ready","reason":"wants a quote this week"}"#)
    #expect(q.score == 82)
    #expect(q.company == "Acme Corp")
    #expect(q.intent == .ready)
    #expect(q.reason == "wants a quote this week")
    #expect(q.tier == .hot)
}

@Test func parseToleratesSurroundingProseAndFloatScore() {
    let q = LeadQualification.parse(
        #"Here: {"score":55.7,"company":"Beta LLC","intent":"Evaluating","reason":"comparing vendors"} ok"#)
    #expect(q.score == 55)
    #expect(q.intent == .evaluating)
    #expect(q.tier == .warm)
}

@Test func scoreIsClampedTo0Through100() {
    #expect(LeadQualification.parse(#"{"score":250,"company":"","intent":"ready","reason":""}"#).score == 100)
    #expect(LeadQualification.parse(#"{"score":-40,"company":"","intent":"ready","reason":""}"#).score == 0)
}

@Test func stringScoreIsParsedThenClamped() {
    let q = LeadQualification.parse(#"{"score":"77","company":"X","intent":"ready","reason":"y"}"#)
    #expect(q.score == 77)
    #expect(q.tier == .hot)
}

@Test func unknownIntentFallsBackToInfoScorePreserved() {
    let q = LeadQualification.parse(#"{"score":65,"company":"Z","intent":"spaceship","reason":"?"}"#)
    #expect(q.intent == .info)
    #expect(q.score == 65)
    #expect(q.tier == .warm)
}

@Test func malformedJsonFallsBackToColdNeverCrashes() {
    for raw in ["{ this is not json", "", #"{"reason":"only reason"}"#, "I cannot comply </think>"] {
        let q = LeadQualification.parse(raw)
        #expect(q.score == 0)
        #expect(q.intent == .info)
        #expect(q.company == nil)
        #expect(q.tier == .cold)
    }
}

@Test func blankCompanyBecomesNil() {
    #expect(LeadQualification.parse(#"{"score":50,"company":"   ","intent":"info","reason":"r"}"#).company == nil)
    #expect(LeadQualification.parse(#"{"score":50,"company":"Acme","intent":"info","reason":"r"}"#).company == "Acme")
}
