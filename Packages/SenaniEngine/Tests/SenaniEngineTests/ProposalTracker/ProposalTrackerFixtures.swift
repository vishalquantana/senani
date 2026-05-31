import Foundation
@testable import SenaniEngine
import SenaniRules

enum PT {
    static let account = "ramesh@quantana.in"
    static let client = "sarah@client.com"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// An OUTBOUND proposal email the user sent to a client, with an attached doc.
    static func outboundProposal(
        id: String = "m-out",
        to: [String] = [client],
        subject: String = "Our proposal for the Q3 engagement",
        body: String = "Hi Sarah,\n\nPlease find our proposal attached. Happy to discuss.\n\nRamesh",
        hasAttachment: Bool = true,
        threadId: String = "t1",
        date: Date = now
    ) -> Message {
        Message(
            id: id, from: account, to: to, subject: subject, body: body,
            hasAttachment: hasAttachment, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: true
        )
    }

    /// An INBOUND reply from the client on the same thread.
    static func inboundReply(
        id: String = "m-reply",
        from: String = client,
        subject: String = "Re: Our proposal for the Q3 engagement",
        body: String,
        threadId: String = "t1",
        date: Date = now.addingTimeInterval(3600)
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: false
        )
    }

    /// A plain outbound message that is NOT a proposal (no attachment, no cues).
    static func ordinaryOutbound(threadId: String = "t9") -> Message {
        Message(
            id: "m-ord", from: account, to: [client], subject: "Lunch next week?",
            body: "Are you free Tuesday?", hasAttachment: false, listUnsubscribeHeader: nil,
            labels: [], threadId: threadId, date: now, isFromUser: true
        )
    }

    static func dealAt(_ stage: DealStage, contact: String = client, value: Double? = nil) -> Deal {
        Deal(id: contact, contactEmail: contact, company: nil, stage: stage,
             score: nil, value: value, lastTouch: now.addingTimeInterval(-86400), 
             sourceMessageId: "seed")
    }

    /// Builds an AgentContext with the given thread, pipeline, and extracted document fields.
    static func context(
        thread: [Message],
        pipeline: any PipelineStore,
        documentFields: [String: String] = [:]
    ) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now,
            documentFields: documentFields, pipeline: pipeline
        )
    }
}
