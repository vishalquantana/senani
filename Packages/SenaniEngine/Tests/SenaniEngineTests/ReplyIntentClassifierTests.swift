import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniInference

/// Finding 1: ReplyIntentClassifier must tolerate model output that is NOT pure JSON
/// (prose-wrapped, markdown-fenced, garbage, empty) and never crash — falling back to a
/// safe default (`.negotiation`, never a silent jump to `.won`/`.lost`).
@Suite struct ReplyIntentClassifierRobustnessTests {

    private func reply(_ body: String = "ok") -> Message {
        Message(id: "r1", from: "client@x.com", to: ["me@x.com"], subject: "Re: proposal",
                body: body, hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t1", date: Date(timeIntervalSince1970: 1_000), isFromUser: false)
    }

    private func classify(modelOutput: String) async throws -> DealStage {
        let gen = FakeTextGenerator(response: modelOutput)
        let classifier = ReplyIntentClassifier(generator: gen)
        return try await classifier.classify(reply: reply())
    }

    // MARK: parseIntent unit coverage (pure)

    @Test func parsesProseWrappedAcceptIntent() {
        // Before the fix this returns "other" (whole-string JSON parse fails on the prose).
        let raw = "Sure! Here is the result:\n{\"intent\": \"accept\"}\nHope that helps."
        #expect(ReplyIntentClassifier.parseIntent(raw) == "accept")
    }

    @Test func parsesMarkdownFencedDeclineIntent() {
        let raw = "```json\n{\"intent\": \"decline\"}\n```"
        #expect(ReplyIntentClassifier.parseIntent(raw) == "decline")
    }

    @Test func emptyInputFallsBackToOther() {
        #expect(ReplyIntentClassifier.parseIntent("") == "other")
    }

    @Test func malformedInputFallsBackToOther() {
        #expect(ReplyIntentClassifier.parseIntent("{ this is not json") == "other")
        #expect(ReplyIntentClassifier.parseIntent("totally prose, no braces") == "other")
    }

    // MARK: end-to-end stage mapping over tolerant parse

    @Test func proseWrappedAcceptMapsToWon() async throws {
        let stage = try await classify(modelOutput: "Result: {\"intent\":\"accept\"} done")
        #expect(stage == .won)
    }

    @Test func garbageMapsToNegotiationNeverWonOrLost() async throws {
        let stage = try await classify(modelOutput: "I cannot help with that.")
        #expect(stage == .negotiation)
    }

    @Test func emptyOutputMapsToNegotiation() async throws {
        let stage = try await classify(modelOutput: "")
        #expect(stage == .negotiation)
    }
}
