import Foundation

/// Pure parser for the RFC 2369 / RFC 8058 `List-Unsubscribe` header value, which is a
/// comma-separated list of (optionally angle-bracketed) URIs, e.g.
/// `<mailto:unsub@brand.com?subject=bye>, <https://brand.com/u/abc>`.
/// Extracts the first `mailto:` address (query stripped) and the first `http(s):` URL.
/// Never throws; unknown/empty inputs yield `nil` fields.
public struct ListUnsubscribeParser: Sendable, Equatable {
    public let mailto: String?
    public let https: String?

    public init(mailto: String?, https: String?) {
        self.mailto = mailto
        self.https = https
    }

    /// True if at least one actionable unsubscribe target was found.
    public var hasAny: Bool { mailto != nil || https != nil }

    public static func parse(_ header: String) -> ListUnsubscribeParser {
        var mailto: String? = nil
        var https: String? = nil

        // Split on commas; trim each token and strip surrounding angle brackets.
        for rawToken in header.split(separator: ",") {
            var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("<") { token.removeFirst() }
            if token.hasSuffix(">") { token.removeLast() }
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = token.lowercased()

            if mailto == nil, lower.hasPrefix("mailto:") {
                let addressPart = String(token.dropFirst("mailto:".count))
                // Strip any ?query (e.g. ?subject=unsub) and surrounding whitespace.
                let address = addressPart.split(separator: "?", maxSplits: 1).first
                    .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if address.contains("@") { mailto = address }
            } else if https == nil, lower.hasPrefix("https://") || lower.hasPrefix("http://") {
                https = token
            }
        }

        return ListUnsubscribeParser(mailto: mailto, https: https)
    }
}
