import Foundation
@testable import SenaniEngine
import SenaniRules

enum RD {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func incoming(
        id: String = "m-in",
        from: String = "sarah@client.com",
        to: [String] = [account],
        subject: String = "Proposal follow-up",
        body: String = "Hi Ramesh,\n\nCould you send the latest figures?\n\nThanks,\nSarah",
        threadId: String = "t1",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: false
        )
    }

    static func priorFromUser(
        id: String = "m-prior",
        threadId: String = "t1",
        body: String = "Hi Sarah, sending the proposal now.",
        date: Date = Date(timeIntervalSince1970: 1_699_000_000)
    ) -> Message {
        Message(
            id: id, from: account, to: ["sarah@client.com"], subject: "Proposal",
            body: body, hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: true
        )
    }

    static func context(thread: [Message], needsReply: Bool) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now, needsReply: needsReply,
            pipeline: InMemoryPipelineStore()
        )
    }
}
