import Foundation

/// Shared, tolerant JSON-object extractor used by every model-output parser in the engine
/// (`ReplyIntentClassifier`, `TriageClassification`, `LeadQualification`).
///
/// Model output is untrusted: it may be prose-wrapped, fenced in markdown, prefixed with a
/// chain-of-thought, or empty. Rather than requiring the WHOLE output to be valid JSON, this
/// returns the first *balanced* `{...}` object found in the text (string-literal aware, so
/// braces inside quoted values do not confuse the matcher). Returns `nil` when no balanced
/// object exists; callers fall back to a safe default. It never throws or crashes.
enum JSONExtraction {
    /// The bytes of the first balanced `{...}` object in `raw`, tolerating surrounding prose.
    /// Returns `nil` if there is no opening brace or the object never closes.
    static func firstObject(in raw: String) -> Data? {
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
