public protocol Embedder: Sendable {
    func embed(_ text: String) async throws -> [Float]
}
