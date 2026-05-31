import Testing
@testable import SenaniApp

struct UpdateDecisionTests {
    @Test func offersWhenFeedIsNewer() {
        let item = FeedItem(version: "1.5.0", title: "Senani 1.5.0", url: "https://updates.example.invalid/Senani-1.5.0.zip")
        let d = UpdateDecision.evaluate(currentVersion: "1.4.2", feedItem: item)
        #expect(d == .updateAvailable(item))
    }

    @Test func noUpdateWhenSameVersion() {
        let item = FeedItem(version: "1.4.2", title: "Senani 1.4.2", url: "https://updates.example.invalid/Senani-1.4.2.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.2", feedItem: item) == .upToDate)
    }

    @Test func noUpdateWhenFeedIsOlder() {
        let item = FeedItem(version: "1.3.9", title: "Senani 1.3.9", url: "https://updates.example.invalid/Senani-1.3.9.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: item) == .upToDate)
    }

    @Test func malformedFeedVersionMeansNoUpdate() {
        let item = FeedItem(version: "not-a-version", title: "broken", url: "https://x.invalid/a.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: item) == .unreadableFeed)
    }

    @Test func malformedCurrentVersionMeansNoUpdate() {
        let item = FeedItem(version: "2.0.0", title: "ok", url: "https://x.invalid/a.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "", feedItem: item) == .unreadableFeed)
    }

    @Test func nilFeedItemMeansNoUpdate() {
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: nil) == .unreadableFeed)
    }
}
