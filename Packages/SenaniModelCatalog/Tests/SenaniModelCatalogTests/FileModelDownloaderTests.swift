import Testing
import Foundation
@testable import SenaniModelCatalog

private func model(_ files: [String] = ["config.json", "model.safetensors"]) -> ModelInfo {
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit", sizeBytes: 1000, files: files)
}

@Test func downloadsEachFileIntoCacheDirAndReportsComplete() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let progress = ThreadSafeArray<Double>()
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in Data("weights".utf8) })

    let path = try await downloader.download(model()) { p in progress.append(p.fraction) }

    let dir = URL(fileURLWithPath: path)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
    #expect(progress.last == 1.0)
    #expect(progress.first ?? 1.0 < 1.0)        // progressed from <1 to 1
}

@Test func isIdempotentWhenAlreadyCached() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let fetchCount = ThreadSafeCounter()
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in
        fetchCount.increment(); return Data("weights".utf8)
    })

    _ = try await downloader.download(model()) { _ in }
    #expect(fetchCount.value == 2)                     // two files fetched first time

    let secondPath = try await downloader.download(model()) { _ in }
    #expect(fetchCount.value == 2)                      // no re-fetch: fully cached
    #expect(downloader.isCached(model()) == true)
    #expect(FileManager.default.fileExists(atPath: secondPath))
}

@Test func partialCacheResumesOnlyMissingFiles() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    // Pre-create the model dir with ONE of the two files present.
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in Data("weights".utf8) })
    let dir = URL(fileURLWithPath: downloader.localPath(for: model()))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("present".utf8).write(to: dir.appendingPathComponent("config.json"))

    let fetched = ThreadSafeArray<URL>()
    let resuming = FileModelDownloader(baseDirectory: base, fileFetcher: { url in fetched.append(url); return Data("w".utf8) })
    _ = try await resuming.download(model()) { _ in }
    #expect(fetched.count == 1)                   // only the missing model.safetensors
    #expect(fetched.first?.absoluteString.hasSuffix("model.safetensors") == true)
}

@Test func fetcherErrorSurfacesAsDownloadError() async {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in
        throw DownloadError.transport("boom")
    })
    await #expect(throws: DownloadError.self) {
        _ = try await downloader.download(model()) { _ in }
    }
}
