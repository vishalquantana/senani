import Foundation
import SenaniVoice
import SenaniInference
import SenaniStore

public protocol VoicePrefixProviding: Sendable {
    func voicePrefix(recipient: String, draftGoal: String) async throws -> String
}

public struct VoiceConditionerPrefixProvider: VoicePrefixProviding {
    private let conditioner: VoiceConditioner
    private let profile: VoiceProfile

    public init(conditioner: VoiceConditioner, profile: VoiceProfile) {
        self.conditioner = conditioner
        self.profile = profile
    }

    public func voicePrefix(recipient: String, draftGoal: String) async throws -> String {
        try await conditioner.promptPrefix(profile: profile, recipient: recipient, draftGoal: draftGoal)
    }
}
