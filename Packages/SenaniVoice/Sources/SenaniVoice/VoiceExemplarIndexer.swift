import SenaniInference
import SenaniRules
import SenaniStore

public struct VoiceExemplarIndexer: Sendable {
    private let embedder: any Embedder
    private let index: any VectorIndex

    public init(embedder: any Embedder, index: any VectorIndex) {
        self.embedder = embedder
        self.index = index
    }

    public func index(sent messages: [Message]) async throws {
        for message in messages where message.isFromUser {
            let vector = try await embedder.embed(message.body)
            try index.insert(id: message.id, vector: vector, metadata: [
                "messageId": message.id,
                "domain": message.to.first.flatMap(VoiceProfileBuilder.domain(of:)) ?? "",
                "text": message.body,
            ])
        }
    }
}
