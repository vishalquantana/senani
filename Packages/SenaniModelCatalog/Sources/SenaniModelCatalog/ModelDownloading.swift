import Foundation

public enum DownloadError: Error, Sendable, Equatable {
    case transport(String)
    case writeFailed(String)
}

/// Progress for one model download.
public struct DownloadProgress: Sendable, Equatable {
    public let filesCompleted: Int
    public let filesTotal: Int
    public var fraction: Double {
        filesTotal == 0 ? 1.0 : Double(filesCompleted) / Double(filesTotal)
    }
    public init(filesCompleted: Int, filesTotal: Int) {
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
    }
}

/// Seam the ModelManager and UI depend on. The live impl is FileModelDownloader.
public protocol ModelDownloading: Sendable {
    /// Returns the local directory path holding the model's files.
    func download(_ model: ModelInfo, onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String
    func isCached(_ model: ModelInfo) -> Bool
    func localPath(for model: ModelInfo) -> String
}
