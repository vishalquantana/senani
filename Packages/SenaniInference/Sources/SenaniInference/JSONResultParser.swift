import Foundation

public enum JSONResultParser {
    public static func parseBoolResults(_ raw: String, key: String = "results") -> [Bool]? {
        guard let data = firstJSONObjectData(in: raw),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let rawArray = dictionary[key] as? [Any]
        else {
            return nil
        }

        var results: [Bool] = []
        results.reserveCapacity(rawArray.count)
        for value in rawArray {
            guard let bool = coerceBool(value) else {
                return nil
            }
            results.append(bool)
        }
        return results
    }

    private static func coerceBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            if number == 1 {
                return true
            }
            if number == 0 {
                return false
            }
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func firstJSONObjectData(in raw: String) -> Data? {
        let characters = Array(raw)
        guard let start = characters.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index]).data(using: .utf8)
                }
            }
            index += 1
        }
        return nil
    }
}
