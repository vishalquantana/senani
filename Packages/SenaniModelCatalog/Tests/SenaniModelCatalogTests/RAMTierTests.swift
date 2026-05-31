import Testing
@testable import SenaniModelCatalog

private let giB: UInt64 = 1024 * 1024 * 1024

@Test func detectsEightGigTier() {
    #expect(RAMTier.detect(physicalMemory: 8 * giB) == .gb8)
    #expect(RAMTier.detect(physicalMemory: 11 * giB) == .gb8)
}

@Test func detectsSixteenGigTier() {
    #expect(RAMTier.detect(physicalMemory: 16 * giB) == .gb16)
    #expect(RAMTier.detect(physicalMemory: 12 * giB) == .gb16)
    #expect(RAMTier.detect(physicalMemory: 23 * giB) == .gb16)
}

@Test func detectsThirtyTwoGigTier() {
    #expect(RAMTier.detect(physicalMemory: 24 * giB) == .gb32)
    #expect(RAMTier.detect(physicalMemory: 64 * giB) == .gb32)
}

@Test func tierExposesBudgetAndDefault() {
    #expect(RAMTier.gb8.maxModelBytes == 3_000_000_000)
    #expect(RAMTier.gb16.maxModelBytes == 7_000_000_000)
    #expect(RAMTier.gb32.maxModelBytes == 20_000_000_000)
    #expect(RAMTier.gb8.defaultModelId == "mlx-community/gemma-3-1b-it-4bit")
    #expect(RAMTier.gb16.defaultModelId == "mlx-community/gemma-3-4b-it-4bit")
    #expect(RAMTier.gb32.defaultModelId == "mlx-community/gemma-3-12b-it-4bit")
}
