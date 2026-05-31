import Foundation
import MLX
import MLXEmbedders
import SenaniInference

public final class EmbeddingGemmaMLXEmbedder: SenaniInference.Embedder, @unchecked Sendable {
    public let configuration: SenaniInference.EmbeddingGemmaConfiguration
    private let container: ModelContainer

    public init(configuration: SenaniInference.EmbeddingGemmaConfiguration) async throws {
        guard FileManager.default.fileExists(atPath: configuration.modelPath) else {
            throw SenaniInference.InferenceError.modelNotLoaded
        }

        let modelURL = URL(fileURLWithPath: configuration.modelPath, isDirectory: true)
            .standardizedFileURL
        self.configuration = configuration
        self.container = try await MLXEmbedders.loadModelContainer(
            configuration: ModelConfiguration(directory: modelURL)
        )
    }

    public convenience init(
        modelPath: String,
        outputDimension: SenaniInference.EmbeddingDimension = .full
    ) async throws {
        try await self.init(
            configuration: SenaniInference.EmbeddingGemmaConfiguration(
                modelPath: modelPath,
                outputDimension: outputDimension
            )
        )
    }

    public func embed(_ text: String) async throws -> [Float] {
        let input = SenaniInference.EmbeddingGemmaEmbedder.truncateInput(text)
        let raw = try await container.perform { model, tokenizer, pooler in
            let tokens = tokenizer.encode(text: input, addSpecialTokens: true)
            guard !tokens.isEmpty else {
                return [Float]()
            }
            guard let padToken = tokenizer.eosTokenId else {
                throw SenaniInference.InferenceError.generationFailed(
                    "EmbeddingGemma tokenizer does not expose a padding token"
                )
            }

            let padded = stacked([MLXArray(tokens)])
            let mask = (padded .!= padToken)
            let tokenTypes = MLXArray.zeros(like: padded)
            let outputs = model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let pooled = pooler(outputs, mask: mask, normalize: true, applyLayerNorm: false)
            pooled.eval()

            switch pooled.shape.count {
            case 2:
                return pooled.map { $0.asArray(Float.self) }.first ?? []
            case 3:
                let reduced = mean(pooled, axis: 1)
                reduced.eval()
                return reduced.map { $0.asArray(Float.self) }.first ?? []
            default:
                throw SenaniInference.InferenceError.generationFailed(
                    "EmbeddingGemma pooling produced unsupported shape \(pooled.shape)"
                )
            }
        }

        return SenaniInference.EmbeddingVector.truncateAndNormalize(
            raw,
            dimension: configuration.outputDimension
        )
    }
}
