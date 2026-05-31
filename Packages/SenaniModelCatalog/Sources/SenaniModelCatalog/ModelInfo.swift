import Foundation

/// One Hugging Face `mlx-community` Gemma model the picker can offer.
public struct ModelInfo: Sendable, Equatable, Identifiable {
    public let id: String                 // full HF repo id, e.g. "mlx-community/gemma-3-4b-it-4bit"
    public let sizeBytes: Int64?          // total on-disk size; nil if HF did not report it
    public let files: [String]            // sibling file names to download

    public init(id: String, sizeBytes: Int64?, files: [String]) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.files = files
    }

    /// Repo id without the "mlx-community/" owner prefix.
    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Human-readable size for the picker UI.
    public static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown size" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB]
        fmt.countStyle = .decimal
        return fmt.string(fromByteCount: bytes)
    }
}
