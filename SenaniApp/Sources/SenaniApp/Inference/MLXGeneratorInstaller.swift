import Foundation
import SenaniInference
import SenaniModelCatalog

/// Bridges the catalog's `GeneratorInstalling` seam to the live MLX path.
/// On install, constructs `MLXTextGenerator(modelPath:)` and hands it to the
/// composition root via the injected setter. This is the ONE place the app
/// links the concrete MLX generator (§3: composition root owns `generator`).
///
/// Construction is host-only by contract: MLXTextGenerator assumes Apple-Silicon
/// MLX weights on disk. We do NOT run it in tests — the catalog package tests
/// use SpyInstaller instead, so nothing here needs MLX to be linked at test time.
public struct MLXGeneratorInstaller: GeneratorInstalling {
    private let setGenerator: @Sendable (any TextGenerator) -> Void

    public init(setGenerator: @escaping @Sendable (any TextGenerator) -> Void) {
        self.setGenerator = setGenerator
    }

    public func install(modelPath: String) throws {
        let generator = MLXTextGenerator(modelPath: modelPath)
        setGenerator(generator)
    }
}
