import Foundation

public indirect enum JSONSchema: Sendable, Equatable {
    case boolean
    case string
    case number
    case array(element: JSONSchema)
    case object(properties: [String: JSONSchema], required: [String])

    public static func boolArrayResults(key: String) -> JSONSchema {
        .object(properties: [key: .array(element: .boolean)], required: [key])
    }

    public init(json: String) {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let schema = Self.parseSchema(object)
        else {
            self = .object(properties: [:], required: [])
            return
        }
        self = schema
    }

    private static func parseSchema(_ object: Any) -> JSONSchema? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let type = dictionary["type"] as? String {
            switch type {
            case "boolean":
                return .boolean
            case "string":
                return .string
            case "number", "integer":
                return .number
            case "array":
                let itemSchema = dictionary["items"].flatMap(parseSchema) ?? .string
                return .array(element: itemSchema)
            case "object":
                let rawProperties = dictionary["properties"] as? [String: Any] ?? [:]
                let properties = rawProperties.mapValues { parseSchema($0) ?? .string }
                let required = dictionary["required"] as? [String] ?? []
                return .object(properties: properties, required: required)
            default:
                return nil
            }
        }
        return nil
    }
}
