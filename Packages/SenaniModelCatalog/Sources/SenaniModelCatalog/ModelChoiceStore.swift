import Foundation

/// The persisted selection: which model, and where its weights live on disk.
public struct ModelChoice: Sendable, Equatable, Codable {
    public let modelId: String
    public let localPath: String
    public init(modelId: String, localPath: String) {
        self.modelId = modelId
        self.localPath = localPath
    }
}

/// Persistence seam so the chosen model auto-loads next launch.
public protocol ModelChoiceStore: Sendable {
    func save(_ choice: ModelChoice)
    func load() -> ModelChoice?
    func clear()
}

/// UserDefaults-backed implementation (production: `.standard`; tests: a throwaway suite).
public struct UserDefaultsModelChoiceStore: ModelChoiceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "senani.selectedModelChoice"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(_ choice: ModelChoice) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }

    public func load() -> ModelChoice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ModelChoice.self, from: data)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}
