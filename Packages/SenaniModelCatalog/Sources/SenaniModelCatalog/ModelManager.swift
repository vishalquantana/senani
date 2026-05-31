import Foundation

/// Orchestrates the picker flow: download (idempotent) → install the generator → persist the choice;
/// and re-installs the persisted choice on launch without re-downloading.
public struct ModelManager: Sendable {
    private let downloader: ModelDownloading
    private let installer: GeneratorInstalling
    private let choices: ModelChoiceStore

    public init(downloader: ModelDownloading, installer: GeneratorInstalling, choices: ModelChoiceStore) {
        self.downloader = downloader
        self.installer = installer
        self.choices = choices
    }

    /// Download (or reuse cached) weights, install the live generator, persist the selection.
    public func chooseAndActivate(_ model: ModelInfo,
                                  onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws {
        let path = try await downloader.download(model, onProgress: onProgress)
        try installer.install(modelPath: path)
        choices.save(ModelChoice(modelId: model.id, localPath: path))
    }

    /// On launch: if a prior choice's weights are still on disk, install it (no download).
    /// Returns true if a generator was installed.
    @discardableResult
    public func loadPersistedOnLaunch() throws -> Bool {
        guard let choice = choices.load() else { return false }
        guard FileManager.default.fileExists(atPath: choice.localPath) else { return false }
        try installer.install(modelPath: choice.localPath)
        return true
    }
}
