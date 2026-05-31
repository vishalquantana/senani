import Foundation

/// Pure, Sparkle-free numeric version. Mirrors the subset of
/// `SUStandardVersionComparator` behavior our appcast uses: dot-separated
/// numeric components, where trailing zeros are insignificant (1.4 == 1.4.0).
public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let l = lhs.components, r = rhs.components
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// Drops insignificant trailing zeros so 1.4 and 1.4.0 compare equal.
    private static func normalized(_ c: [Int]) -> [Int] {
        var out = c
        while out.count > 1, out.last == 0 { out.removeLast() }
        return out
    }
}
