public struct GrammarMask: Sendable, Equatable {
    public let schema: JSONSchema

    public init(schema: JSONSchema) throws {
        self.schema = schema
        guard case .object = schema else {
            throw InferenceError.decodingFailed("Only object JSON schemas are supported")
        }
    }
}
