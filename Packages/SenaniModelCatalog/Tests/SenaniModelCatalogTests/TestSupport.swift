import Foundation
@testable import SenaniModelCatalog

/// HTTP client double: returns canned bytes or throws a canned error. NEVER touches the network.
final class FakeCatalogHTTPClient: CatalogHTTPClient, @unchecked Sendable {
    let data: Data?
    let error: Error?
    private(set) var requestedURLs: [URL] = []

    init(cannedJSON: String) { self.data = Data(cannedJSON.utf8); self.error = nil }
    init(error: Error) { self.data = nil; self.error = error }

    func get(_ url: URL) async throws -> Data {
        requestedURLs.append(url)
        if let error { throw error }
        return data ?? Data()
    }
}

enum CannedHF {
    /// 3 gemma-4bit repos + 1 unrelated repo (must be filtered out by ModelCatalog.fetch).
    static let gemmaList = """
    [
      { "id": "mlx-community/gemma-3-1b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 800000000 },
                      { "rfilename": "config.json", "size": 900 },
                      { "rfilename": "tokenizer.json", "size": 100 } ] },
      { "id": "mlx-community/gemma-3-4b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 2400000000 },
                      { "rfilename": "config.json", "size": 1200 } ] },
      { "id": "mlx-community/gemma-3-12b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 7000000000 } ] },
      { "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 4000000000 } ] }
    ]
    """

    /// One gemma-4bit repo whose siblings report no size.
    static let noSizes = """
    [
      { "id": "mlx-community/gemma-3-4b-it-4bit",
        "siblings": [ { \"rfilename\": \"model.safetensors\" },
                      { \"rfilename\": \"config.json\" } ] }
    ]
    """
}

/// Create a fresh temporary directory and return its URL; caller removes it.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("senani-catalog-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ThreadSafeArray<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [T] = []
    func append(_ element: T) { lock.lock(); defer { lock.unlock() }; elements.append(element) }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return elements }
    var last: T? { lock.lock(); defer { lock.unlock() }; return elements.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return elements.count }
    var first: T? { lock.lock(); defer { lock.unlock() }; return elements.first }
}

final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// ---- doubles for ModelManager ----

final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    var base: URL
    private(set) var downloadedIds: [String] = []
    init(base: URL) { self.base = base }
    func localPath(for model: ModelInfo) -> String {
        base.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "__")).path
    }
    func isCached(_ model: ModelInfo) -> Bool {
        FileManager.default.fileExists(atPath: localPath(for: model))
    }
    func download(_ model: ModelInfo, onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String {
        downloadedIds.append(model.id)
        let dir = URL(fileURLWithPath: localPath(for: model))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        onProgress(DownloadProgress(filesCompleted: 1, filesTotal: 1))
        return dir.path
    }
}

final class SpyInstaller: GeneratorInstalling, @unchecked Sendable {
    private(set) var installedPaths: [String] = []
    func install(modelPath: String) throws { installedPaths.append(modelPath) }
}
