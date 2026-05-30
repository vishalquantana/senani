import Foundation
import SenaniInference
import SenaniRules
import SenaniStore
import Testing
@testable import SenaniVoice

@Suite struct VoiceContractTests {
    @Test func buildsProfileAndDomainVariation() {
        let profile = VoiceProfileBuilder.build(from: [
            Self.msg("m1", to: ["a@acme.com"], body: "Hi Sarah\nThanks so much. Sounds good.\nBest", isFromUser: true),
            Self.msg("m2", to: ["b@acme.com"], body: "Hi Sarah\nThanks so much. I can help.\nBest", isFromUser: true),
        ])
        #expect(profile.greeting == "Hi Sarah")
        #expect(profile.signoff == "Best")
        #expect(profile.commonPhrases.contains("thanks so"))
        #expect(profile.perDomain["acme.com"] != nil)
    }

    @Test func persistsProfile() throws {
        let store = VoiceProfileStore(database: try SenaniDatabase.inMemory(), now: { 1 })
        let profile = VoiceProfile(scope: "global", averageSentenceWords: 4, greeting: "Hi", signoff: "Best", commonPhrases: ["thanks"], emojiRate: 0)
        try store.save(profile)
        #expect(try store.load() == profile)
    }

    @Test func indexesSentMailAndBuildsConditioningPrompt() async throws {
        let index = InMemoryVectorIndex()
        let embedder = FakeEmbedder()
        let indexer = VoiceExemplarIndexer(embedder: embedder, index: index)
        try await indexer.index(sent: [Self.msg("m1", to: ["a@acme.com"], body: "Thanks so much", isFromUser: true)])
        #expect(index.count == 1)
        #expect(index.entries.first?.metadata["domain"] == "acme.com")

        let conditioner = VoiceConditioner(embedder: embedder, index: index)
        let profile = VoiceProfile(scope: "global", averageSentenceWords: 3, greeting: "Hi", signoff: "Best", commonPhrases: ["thanks"], emojiRate: 0)
        let prompt = try await conditioner.promptPrefix(profile: profile, recipient: "a@acme.com", draftGoal: "reply")
        #expect(prompt.contains("Thanks so much"))
        #expect(prompt.contains("Average sentence length"))
    }

    @Test func overrideAppliesFocusedChanges() {
        let profile = VoiceProfile(scope: "global", averageSentenceWords: 3, greeting: "Hi", signoff: "Best", commonPhrases: ["thanks"], emojiRate: 0)
        let changed = applyOverride(VoiceOverride(signoff: "Cheers"), to: profile)
        #expect(changed.greeting == "Hi")
        #expect(changed.signoff == "Cheers")
    }

    static func msg(_ id: String, to: [String], body: String, isFromUser: Bool) -> Message {
        Message(
            id: id,
            from: isFromUser ? "me@example.com" : "sender@example.com",
            to: to,
            subject: "Subject",
            body: body,
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: [],
            threadId: "t",
            date: Date(timeIntervalSince1970: 0),
            isFromUser: isFromUser
        )
    }
}

final class FakeEmbedder: Embedder, @unchecked Sendable {
    func embed(_ text: String) async throws -> [Float] {
        [Float(text.count), 1]
    }
}
