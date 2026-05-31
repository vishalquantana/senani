import Foundation
@testable import SenaniEngine
import SenaniRules

enum FU {
    static let account = "ramesh@quantana.in"
    static let contact = "sarah@client.com"
    /// "Now" reference for the fake clock: 2023-11-14 22:13:20 UTC.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func day(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A message FROM the user out to the contact (our outreach in the thread).
    static func fromUser(
        id: String = "m-user",
        threadId: String = "t1",
        subject: String = "Proposal",
        body: String = "Hi Sarah,\n\nHere's the proposal — let me know what you think.\n\nBest,\nRamesh",
        daysAgo: Double = 10
    ) -> Message {
        Message(
            id: id, from: account, to: [contact], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: now.addingTimeInterval(-day(daysAgo)), isFromUser: true
        )
    }

    /// A message FROM the contact back to the user (a reply).
    static func fromContact(
        id: String = "m-contact",
        threadId: String = "t1",
        subject: String = "Re: Proposal",
        body: String = "Thanks Ramesh, reviewing now.",
        daysAgo: Double = 2
    ) -> Message {
        Message(
            id: id, from: contact, to: [account], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: now.addingTimeInterval(-day(daysAgo)), isFromUser: false
        )
    }

    static func openDeal(
        id: String = "d1", threadId: String = "t1",
        stage: DealStage = .proposal, lastTouch: Date? = nil
    ) -> Deal {
        Deal(id: id, contactEmail: contact, stage: stage, lastTouch: lastTouch ?? now.addingTimeInterval(-day(10)), sourceMessageId: threadId)
    }

    /// Builds an AgentContext over the given thread.
    static func context(thread: [Message], at when: Date = now, pipeline: PipelineStore = NullPipelineStore()) -> AgentContext {
        AgentContext(
            account: account, thread: thread.sorted { $0.date < $1.date },
            rules: [], retrieve: { _, _ in [] }, now: when, 
            pipeline: pipeline
        )
    }
}
