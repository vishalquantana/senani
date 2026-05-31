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
