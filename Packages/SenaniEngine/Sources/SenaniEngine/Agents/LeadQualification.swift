import Foundation
import SenaniInference

/// The decoded result of one lead qualification. Construction NEVER fails:
/// `parse` clamps the score to 0–100, validates `intent` against the enum, and
/// falls back to score 0 / intent .info / nil company on any deviation.
public struct LeadQualification: Sendable, Equatable {
    public let score: Int            // 0...100 (clamped)
    public let company: String?      // nil if blank/missing
    public let intent: LeadIntent
    public let reason: String

    public init(score: Int, company: String?, intent: LeadIntent, reason: String) {
        self.score = min(100, max(0, score))
        self.company = company
        self.intent = intent
        self.reason = reason
    }

    /// Derived temperature used for the reversible label.
    public var tier: LeadTier { LeadTier(score: score) }

    /// The shape the generator is asked to emit.
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "score": { "type": "integer" },
        "company": { "type": "string" },
        "intent": { "type": "string" },
        "reason": { "type": "string" }
      },
      "required": ["score", "company", "intent", "reason"]
    }
    """

    public static let schema = JSONSchema(json: schemaJSON)

    /// Safe parse: extracts the first balanced JSON object, reads the fields, coerces/clamps
    /// the score, validates intent, nils a blank company. Never throws/crashes; on any failure
    /// returns the Cold fallback (score 0, intent .info, nil company).
    public static func parse(_ raw: String) -> LeadQualification {
        let fallback = LeadQualification(score: 0, company: nil, intent: .info, reason: "")
        guard
            let data = JSONExtraction.firstObject(in: raw),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return fallback
        }
        let score = coerceScore(dict["score"])
        let intent = LeadIntent.parse((dict["intent"] as? String) ?? "")
        let reason = (dict["reason"] as? String) ?? ""
        let rawCompany = (dict["company"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (rawCompany?.isEmpty == false) ? rawCompany : nil
        return LeadQualification(score: score, company: company, intent: intent, reason: reason)
    }

    /// Accepts Int, Double, or numeric String; anything else -> 0. The init clamps to 0...100.
    private static func coerceScore(_ value: Any?) -> Int {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }
}
