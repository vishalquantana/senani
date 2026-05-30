import Foundation

public enum SenaniJSON {
    public enum CodingError: Error {
        case notUTF8
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodingError.notUTF8
        }
        return string
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw CodingError.notUTF8
        }
        return try decoder().decode(type, from: data)
    }
}
