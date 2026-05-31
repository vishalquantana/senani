import Foundation
import SenaniInference

public struct TriageClassification: Sendable, Equatable {
    public let category: TriageCategory
    public let priority: TriagePriority
    public let reason: String

    public init(category: TriageCategory, priority: TriagePriority, reason: String) {
        self.category = category
        self.priority = priority
        self.reason = reason
    }

    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "category": { "type": "string" },
        "priority": { "type": "string" },
        "reason": { "type": "string" }
      },
      "required": ["category", "priority", "reason"]
    }
    """

    public static let schema = JSONSchema(json: schemaJSON)

    public static func parse(_ raw: String) -> TriageClassification {
        guard
            let data = firstJSONObject(in: raw),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return TriageClassification(category: .other, priority: .normal, reason: "")
        }
        let category = TriageCategory.parse((dict["category"] as? String) ?? "")
        let priority = TriagePriority.parse((dict["priority"] as? String) ?? "")
        let reason = (dict["reason"] as? String) ?? ""
        return TriageClassification(category: category, priority: priority, reason: reason)
    }

    private static func firstJSONObject(in raw: String) -> Data? {
        let chars = Array(raw)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false, i = start
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start...i]).data(using: .utf8) }
            }
            i += 1
        }
        return nil
    }
}
