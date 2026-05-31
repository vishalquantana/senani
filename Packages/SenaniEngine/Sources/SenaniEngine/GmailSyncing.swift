import SenaniRules

public protocol GmailSyncing: Sendable {
    func fetchMessages(query: String, maxResults: Int) async throws -> [Message]
}
