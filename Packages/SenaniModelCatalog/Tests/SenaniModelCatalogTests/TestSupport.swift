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
