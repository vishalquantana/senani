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
            let data = JSONExtraction.firstObject(in: raw),
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
}
