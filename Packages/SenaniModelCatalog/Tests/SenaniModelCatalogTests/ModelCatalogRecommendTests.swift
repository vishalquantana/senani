import Testing
@testable import SenaniModelCatalog

private let all: [ModelInfo] = [
    ModelInfo(id: "mlx-community/gemma-3-1b-it-4bit",  sizeBytes: 800_000_000,   files: []),
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit",  sizeBytes: 2_400_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-3-12b-it-4bit", sizeBytes: 7_000_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-3-27b-it-4bit", sizeBytes: 15_000_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-mystery-4bit",  sizeBytes: nil,           files: []),
]

@Test func eightGigKeepsOnlySmallModels() {
    let r = ModelCatalog.recommend(from: all, tier: .gb8)
    #expect(r.models.map(\.id) == ["mlx-community/gemma-3-1b-it-4bit", "mlx-community/gemma-3-4b-it-4bit"])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-1b-it-4bit")
}

@Test func sixteenGigAddsTwelveB() {
    let r = ModelCatalog.recommend(from: all, tier: .gb16)
    #expect(r.models.map(\.id) == [
        "mlx-community/gemma-3-1b-it-4bit",
        "mlx-community/gemma-3-4b-it-4bit",
        "mlx-community/gemma-3-12b-it-4bit",
    ])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func thirtyTwoGigIncludesUnknownSizeSortedLast() {
    let r = ModelCatalog.recommend(from: all, tier: .gb32)
    #expect(r.models.map(\.id) == [
        "mlx-community/gemma-3-1b-it-4bit",
        "mlx-community/gemma-3-4b-it-4bit",
        "mlx-community/gemma-3-12b-it-4bit",
        "mlx-community/gemma-3-27b-it-4bit",
        "mlx-community/gemma-mystery-4bit",   // nil size sorts last, included only at gb32
    ])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-12b-it-4bit")
}

@Test func defaultFallsBackToFirstWhenPreferredAbsent() {
    let onlyLarge = [ModelInfo(id: "mlx-community/gemma-3-12b-it-4bit", sizeBytes: 7_000_000_000, files: [])]
    let r = ModelCatalog.recommend(from: onlyLarge, tier: .gb8)
    #expect(r.models.isEmpty)            // 7GB exceeds the 3GB gb8 budget
    #expect(r.suggestedDefault == nil)
}
