import Foundation

public struct EmbeddingGemmaConfiguration: Sendable, Equatable {
    public static let defaultModelID = "mlx-community/embeddinggemma-300m-4bit"
    public static let upstreamModelID = "google/embeddinggemma-300m"
    public static let contextTokenLimit = 2_048

    public let modelPath: String
    public let outputDimension: EmbeddingDimension

    public init(modelPath: String, outputDimension: EmbeddingDimension = .full) {
        self.modelPath = modelPath
        self.outputDimension = outputDimension
    }
}

/// EmbeddingGemma is the embedding model for Senani retrieval paths.
///
/// The model is separate from the generative Gemma model used by
/// `MLXTextGenerator`: EmbeddingGemma is a Gemma 3 based 308M text encoder with
/// 768-dimensional output and MRL truncation support. This wrapper pins that
/// contract and delegates native execution to the MLX-backed embedder.
public final class EmbeddingGemmaEmbedder: Embedder, @unchecked Sendable {
    public let configuration: EmbeddingGemmaConfiguration
    private let backend: any Embedder

    public convenience init(
        modelPath: String,
        outputDimension: EmbeddingDimension = .full
    ) {
        self.init(
            configuration: EmbeddingGemmaConfiguration(
                modelPath: modelPath,
                outputDimension: outputDimension
            )
        )
    }

    public init(
        configuration: EmbeddingGemmaConfiguration,
        backend: (any Embedder)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend ?? MLXEmbedder(modelPath: configuration.modelPath)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let raw = try await backend.embed(Self.truncateInput(text))
        return EmbeddingVector.truncateAndNormalize(raw, dimension: configuration.outputDimension)
    }

    public static func truncateInput(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > EmbeddingGemmaConfiguration.contextTokenLimit else {
            return text
        }
        return words.prefix(EmbeddingGemmaConfiguration.contextTokenLimit).joined(separator: " ")
    }
}
