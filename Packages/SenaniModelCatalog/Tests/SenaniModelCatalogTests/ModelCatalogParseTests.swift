import Testing
@testable import SenaniModelCatalog

@Test func modelInfoHoldsIdSizeAndFiles() {
    let m = ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit",
                      sizeBytes: 2_400_000_000,
                      files: ["config.json", "model.safetensors"])
    #expect(m.id == "mlx-community/gemma-3-4b-it-4bit")
    #expect(m.sizeBytes == 2_400_000_000)
    #expect(m.files.contains("model.safetensors"))
    #expect(m.shortName == "gemma-3-4b-it-4bit")
}

@Test func formatsBytesForDisplay() {
    #expect(ModelInfo.formatBytes(2_400_000_000).contains("2.4"))
    #expect(ModelInfo.formatBytes(nil) == "unknown size")
}

import Foundation

@Test func parsesHuggingFaceListSummingSiblingSizes() async throws {
    let client = FakeCatalogHTTPClient(cannedJSON: CannedHF.gemmaList)
    let catalog = ModelCatalog(http: client)
    let models = try await catalog.fetch()
    // CannedHF.gemmaList has 3 gemma-4bit repos + 1 non-gemma repo that must be filtered out.
    #expect(models.count == 3)
    let m4b = try #require(models.first { $0.id == "mlx-community/gemma-3-4b-it-4bit" })
    #expect(m4b.sizeBytes == 2_400_001_200)         // 2_400_000_000 + 1_200
    #expect(m4b.files.contains("model.safetensors"))
    #expect(models.allSatisfy { $0.id.lowercased().contains("gemma") })
    #expect(models.allSatisfy { $0.id.lowercased().contains("4bit") })
}

@Test func missingSiblingSizesYieldNilSize() async throws {
    let client = FakeCatalogHTTPClient(cannedJSON: CannedHF.noSizes)
    let catalog = ModelCatalog(http: client)
    let models = try await catalog.fetch()
    #expect(models.count == 1)
    #expect(models[0].sizeBytes == nil)
}

@Test func malformedJSONThrowsCatalogError() async {
    let client = FakeCatalogHTTPClient(cannedJSON: "{ not json")
    let catalog = ModelCatalog(http: client)
    await #expect(throws: CatalogError.self) { _ = try await catalog.fetch() }
}

@Test func httpFailurePropagatesAsCatalogError() async {
    let client = FakeCatalogHTTPClient(error: CatalogError.network("offline"))
    let catalog = ModelCatalog(http: client)
    await #expect(throws: CatalogError.self) { _ = try await catalog.fetch() }
}
