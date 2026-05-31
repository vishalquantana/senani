import Foundation
@testable import SenaniEngine
import SenaniRules

enum OX {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static func day(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A Deal whose lastTouch is `daysAgo` before OX.now.
    static func deal(
        contact: String,
        company: String? = "Acme",
        stage: DealStage = .qualified,
        score: Int? = 70,
        touchedDaysAgo: Double? = nil
    ) -> Deal {
        let lastTouch = touchedDaysAgo.map { now.addingTimeInterval(-day($0)) } ?? now
        return Deal(id: contact, contactEmail: contact, company: company, stage: stage,
                    score: score, value: nil, lastTouch: lastTouch,
                    sourceMessageId: nil)
    }

    /// An OutreachTarget for `contact` with an optional deal and optional prior thread.
    static func target(
        contact: String,
        deal: Deal? = nil,
        thread: [Message] = []
    ) -> OutreachTarget {
        OutreachTarget(contactEmail: contact, deal: deal, thread: thread)
    }

    /// AgentContext for the user's account (outreach is account-scoped, not thread-scoped).
    static func context(now: Date = now) -> AgentContext {
        AgentContext(account: account, thread: [], rules: [],
                     retrieve: { _, _ in [] }, now: now,
                     pipeline: InMemoryPipelineStore())
    }
}
