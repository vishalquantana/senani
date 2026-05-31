import Testing
import Foundation
@testable import SenaniEngine
import SenaniVoice
import SenaniInference
import SenaniStore

actor FakeVoicePrefixProvider: VoicePrefixProviding {
    private let prefix: String
    private(set) var recordedCalls: [(recipient: String, draftGoal: String)] = []

    init(prefix: String) { self.prefix = prefix }

    func voicePrefix(recipient: String, draftGoal: String) async throws -> String {
        recordedCalls.append((recipient, draftGoal))
        return prefix
    }
}

final class ConstantEmbedder: Embedder, @unchecked Sendable {
    func embed(_ text: String) async throws -> [Float] { [0, 0, 0] }
}

@Suite struct VoicePrefixProvidingTests {
    @Test func fakeReturnsCannedPrefixAndRecordsTheCall() async throws {
        let fake = FakeVoicePrefixProvider(prefix: "VOICE-PREFIX")
        let out = try await fake.voicePrefix(recipient: "sarah@client.com", draftGoal: "reply")
        #expect(out == "VOICE-PREFIX")
        let calls = await fake.recordedCalls
        #expect(calls.first?.recipient == "sarah@client.com")
    }

    @Test func conditionerAdapterConformsAndForwardsToVoiceConditioner() async throws {
        let embedder = ConstantEmbedder()
        let index = InMemoryVectorIndex()
        let profile = VoiceProfile(
            scope: "global", averageSentenceWords: 12, greeting: "Hi", signoff: "Best,",
            commonPhrases: ["let me know"], emojiRate: 0
        )
        let adapter = VoiceConditionerPrefixProvider(
            conditioner: VoiceConditioner(embedder: embedder, index: index),
            profile: profile
        )
        let prefix = try await adapter.voicePrefix(recipient: "sarah@client.com", draftGoal: "reply about the proposal")
        #expect(prefix.contains("Best,"))
    }
}
