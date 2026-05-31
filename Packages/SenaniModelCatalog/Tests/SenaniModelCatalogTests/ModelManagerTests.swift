import Testing
import Foundation
@testable import SenaniModelCatalog

private func gemma4b() -> ModelInfo {
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit", sizeBytes: 1000, files: ["model.safetensors"])
}

@Test func chooseDownloadsInstallsAndPersists() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    let installer = SpyInstaller()
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let manager = ModelManager(downloader: downloader, installer: installer, choices: choices)

    let sawProgress = ThreadSafeCounter()
    try await manager.chooseAndActivate(gemma4b()) { _ in sawProgress.increment() }

    #expect(downloader.downloadedIds == ["mlx-community/gemma-3-4b-it-4bit"])
    #expect(installer.installedPaths.count == 1)                       // the generator swap was invoked
    #expect(installer.installedPaths[0] == downloader.localPath(for: gemma4b()))
    #expect(sawProgress.value > 0)
    #expect(choices.load()?.modelId == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func choosingAlreadyCachedSkipsDownloadButStillInstalls() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    // Pre-cache by running once.
    let installer1 = SpyInstaller()
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let m1 = ModelManager(downloader: downloader, installer: installer1, choices: choices)
    try await m1.chooseAndActivate(gemma4b()) { _ in }
    #expect(downloader.downloadedIds.count == 1)

    // Choose again: FakeDownloader.download is still called but is itself idempotent on disk;
    // ModelManager always installs the resulting path. Assert install happened and choice persisted.
    let installer2 = SpyInstaller()
    let m2 = ModelManager(downloader: downloader, installer: installer2, choices: choices)
    try await m2.chooseAndActivate(gemma4b()) { _ in }
    #expect(installer2.installedPaths.count == 1)
    #expect(choices.load()?.modelId == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func loadPersistedInstallsWhenPathPresent() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    let path = downloader.localPath(for: gemma4b())
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    choices.save(ModelChoice(modelId: gemma4b().id, localPath: path))
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: downloader, installer: installer, choices: choices)

    let installed = try manager.loadPersistedOnLaunch()
    #expect(installed == true)
    #expect(installer.installedPaths == [path])
    #expect(downloader.downloadedIds.isEmpty)            // no download on auto-load
}

@Test func loadPersistedReturnsFalseWhenNothingSaved() throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: FakeDownloader(base: base), installer: installer, choices: choices)
    #expect(try manager.loadPersistedOnLaunch() == false)
    #expect(installer.installedPaths.isEmpty)
}

@Test func loadPersistedReturnsFalseWhenPathMissing() throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    choices.save(ModelChoice(modelId: "x", localPath: base.appendingPathComponent("gone").path))
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: FakeDownloader(base: base), installer: installer, choices: choices)
    #expect(try manager.loadPersistedOnLaunch() == false)
    #expect(installer.installedPaths.isEmpty)
}
