import Testing
import Foundation
@testable import SenaniModelCatalog

private func freshDefaults() -> UserDefaults {
    let suite = "senani-choice-tests-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

@Test func savesAndLoadsChosenModel() throws {
    let store = UserDefaultsModelChoiceStore(defaults: freshDefaults())
    #expect(store.load() == nil)
    let choice = ModelChoice(modelId: "mlx-community/gemma-3-4b-it-4bit",
                             localPath: "/tmp/models/gemma")
    store.save(choice)
    let loaded = store.load()
    #expect(loaded == choice)
    #expect(loaded?.modelId == "mlx-community/gemma-3-4b-it-4bit")
    #expect(loaded?.localPath == "/tmp/models/gemma")
}

@Test func clearRemovesTheChoice() throws {
    let store = UserDefaultsModelChoiceStore(defaults: freshDefaults())
    store.save(ModelChoice(modelId: "a", localPath: "/p"))
    store.clear()
    #expect(store.load() == nil)
}
