import Foundation

public enum EmbeddingDimension: Int, Sendable, Equatable, CaseIterable {
    case full = 768
    case mrl512 = 512
    case mrl256 = 256
    case mrl128 = 128
}

public enum EmbeddingVector {
    public static func truncateAndNormalize(
        _ vector: [Float],
        dimension: EmbeddingDimension
    ) -> [Float] {
        let targetCount = min(vector.count, dimension.rawValue)
        guard targetCount > 0 else {
            return []
        }
        return normalize(Array(vector.prefix(targetCount)))
    }

    public static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { partial, value in
            partial + value * value
        }.squareRoot()
        guard norm > 0 else {
            return vector
        }
        return vector.map { $0 / norm }
    }
}
