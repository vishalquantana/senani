/// The composition-root swap point. The app implements this by constructing
/// `SenaniInference.MLXTextGenerator(modelPath:)` and assigning it to
/// `AppEnvironment.generator` (replacing the NotReadyTextGenerator stub).
/// Kept as a seam so this package — and its tests — never link MLX.
public protocol GeneratorInstalling: Sendable {
    func install(modelPath: String) throws
}
