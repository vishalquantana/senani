import Foundation
@testable import SenaniEngine
import SenaniRules

enum IH {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func newsletter(
        id: String = "m-news",
        from: String = "news@brand.com",
        subject: String = "Brand Weekly — your digest",
        listUnsubscribeHeader: String? = "<mailto:unsubscribe@brand.com?subject=unsub>, <https://brand.com/u/abc123>",
        labels: [String] = ["Senani/Category/Newsletter"],
        threadId: String = "t-news",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject,
            body: "Lots of news this week. View in browser.",
            hasAttachment: false, listUnsubscribeHeader: listUnsubscribeHeader, labels: labels,
            threadId: threadId, date: date, isFromUser: false
        )
    }

    static func personal(
        id: String = "m-personal",
        from: String = "sarah@client.com",
        subject: String = "Quick question about the proposal",
        threadId: String = "t-personal"
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject,
            body: "Hi Ramesh, could you confirm the figures?",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: Date(timeIntervalSince1970: 1_700_000_000), isFromUser: false
        )
    }

    static func context(thread: [Message]) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now, pipeline: InMemoryPipelineStore()
        )
    }

    static func repeatSenderThread(domain: String = "brand.com", count: Int) -> [Message] {
        (0..<count).map { i in
            newsletter(
                id: "m-\(domain)-\(i)",
                from: "news@\(domain)",
                listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Newsletter"],
                threadId: "t-\(domain)",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
            )
        }
    }
}
