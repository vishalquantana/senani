import SenaniInference
import SenaniStore

public struct VoiceConditioner: Sendable {
    private let embedder: any Embedder
    private let index: any VectorIndex

    public init(embedder: any Embedder, index: any VectorIndex) {
        self.embedder = embedder
        self.index = index
    }

    public func promptPrefix(profile: VoiceProfile, recipient: String, draftGoal: String) async throws -> String {
        let domain = VoiceProfileBuilder.domain(of: recipient)
        let selected = domain.flatMap { profile.perDomain[$0] } ?? profile
        let vector = try await embedder.embed(draftGoal)
        let exemplars = try index.search(vector: vector, k: 3)
            .filter { hit in domain == nil || hit.metadata["domain"] == domain }
            .compactMap { $0.metadata["text"] }
        return """
        Write in the user's email voice.
        Scope: \(selected.scope)
        Average sentence length: \(String(format: "%.1f", selected.averageSentenceWords)) words.
        Greeting: \(selected.greeting ?? "")
        Signoff: \(selected.signoff ?? "")
        Common phrases: \(selected.commonPhrases.joined(separator: ", "))
        Exemplars:
        \(exemplars.joined(separator: "\n---\n"))
        """
    }
}

public struct VoiceOverride: Sendable, Equatable {
    public var greeting: String?
    public var signoff: String?
    public var commonPhrases: [String]?

    public init(greeting: String? = nil, signoff: String? = nil, commonPhrases: [String]? = nil) {
        self.greeting = greeting
        self.signoff = signoff
        self.commonPhrases = commonPhrases
    }
}

public func applyOverride(_ override: VoiceOverride, to profile: VoiceProfile) -> VoiceProfile {
    var profile = profile
    if let greeting = override.greeting { profile.greeting = greeting }
    if let signoff = override.signoff { profile.signoff = signoff }
    if let commonPhrases = override.commonPhrases { profile.commonPhrases = commonPhrases }
    return profile
}
