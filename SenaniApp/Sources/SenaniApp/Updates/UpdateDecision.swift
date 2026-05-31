import Foundation

/// A single appcast <item> reduced to the fields the decision needs.
/// (In production Sparkle parses the XML; in tests we construct it directly.)
public struct FeedItem: Equatable, Sendable {
    public let version: String       // the `sparkle:version` / shortVersionString
    public let title: String
    public let url: String           // enclosure URL of the .zip/.dmg
    public init(version: String, title: String, url: String) {
        self.version = version
        self.title = title
        self.url = url
    }
}

/// Pure update-offer decision. No Sparkle, no I/O — fully unit-testable.
public enum UpdateDecision: Equatable, Sendable {
    case updateAvailable(FeedItem)
    case upToDate
    case unreadableFeed   // malformed feed item or unparseable current version

    public static func evaluate(currentVersion: String, feedItem: FeedItem?) -> UpdateDecision {
        guard let item = feedItem else { return .unreadableFeed }
        guard let current = SemanticVersion(currentVersion),
              let candidate = SemanticVersion(item.version) else {
            return .unreadableFeed
        }
        return candidate > current ? .updateAvailable(item) : .upToDate
    }
}
