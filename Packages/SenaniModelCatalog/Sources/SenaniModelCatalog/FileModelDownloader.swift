import Foundation

/// Downloads each file of a model from Hugging Face `resolve/main` into a per-model
/// cache directory. Idempotent (skips files already on disk), resumable (only fetches
/// missing files), and progress-reporting. Byte transfer is injected so tests stay offline.
public struct FileModelDownloader: ModelDownloading {
    private let baseDirectory: URL
    private let fileFetcher: @Sendable (URL) async throws -> Data

    /// `baseDirectory` is the cache root (production: Application Support/Senani/models).
    /// `fileFetcher` performs the actual byte transfer for a single file URL.
    public init(baseDirectory: URL,
                fileFetcher: @escaping @Sendable (URL) async throws -> Data = FileModelDownloader.liveFetcher) {
        self.baseDirectory = baseDirectory
        self.fileFetcher = fileFetcher
    }

    /// Live transfer over URLSession.
    public static let liveFetcher: @Sendable (URL) async throws -> Data = { url in
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DownloadError.transport("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.transport(error.localizedDescription)
        }
    }

    public func localPath(for model: ModelInfo) -> String {
        // Replace \"/\" so the repo id becomes a single safe directory name.
        let safe = model.id.replacingOccurrences(of: "/", with: "__")
        return baseDirectory.appendingPathComponent(safe, isDirectory: true).path
    }

    public func isCached(_ model: ModelInfo) -> Bool {
        guard !model.files.isEmpty else { return false }
        let dir = URL(fileURLWithPath: localPath(for: model))
        return model.files.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    public func download(_ model: ModelInfo,
                         onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String {
        let dir = URL(fileURLWithPath: localPath(for: model))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.writeFailed(error.localizedDescription)
        }

        let total = model.files.count
        var completed = 0
        onProgress(DownloadProgress(filesCompleted: 0, filesTotal: total))

        for file in model.files {
            let dest = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                completed += 1
                onProgress(DownloadProgress(filesCompleted: completed, filesTotal: total))
                continue
            }
            guard let url = Self.remoteURL(modelId: model.id, file: file) else {
                throw DownloadError.transport("bad file name: \(file)")
            }
            let data = try await fileFetcher(url)
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                throw DownloadError.writeFailed(error.localizedDescription)
            }
            completed += 1
            onProgress(DownloadProgress(filesCompleted: completed, filesTotal: total))
        }
        return dir.path
    }

    static func remoteURL(modelId: String, file: String) -> URL? {
        URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(file)")
    }
}
