import Foundation
import SenaniRules

/// A thread that has gone silent on an open deal and is due a follow-up nudge.
public struct StaleThread: Sendable, Equatable {
    public let threadId: String
    public let lastUserMessage: Message   // the user's last outreach (the message to reply into)
    public let deal: Deal
    public init(threadId: String, lastUserMessage: Message, deal: Deal) {
        self.threadId = threadId
        self.lastUserMessage = lastUserMessage
        self.deal = deal
    }
}

/// Follow-up timing policy. `silenceDays` = how long a thread may sit unanswered before a nudge;
/// `cooldownDays` = minimum gap between nudges on the same deal (prevents duplicates).
public struct FollowUpPolicy: Sendable, Equatable {
    public let silenceDays: Double
    public let cooldownDays: Double
    public init(silenceDays: Double = 7, cooldownDays: Double = 3) {
        self.silenceDays = silenceDays
        self.cooldownDays = cooldownDays
    }
}

/// PURE staleness scan. Given a thread store + pipeline + policy + an injected `now`, returns the
/// open-deal threads whose last message is the user's, older than `silenceDays`, past cooldown.
/// The Scheduler's DAILY HOOK calls `staleThreads(olderThan:now:)` and routes each result through
/// the Follow-up agent's `proposals(...)` path (per-message reactivation uses the same predicate).
public struct StaleThreadScanner: Sendable {
    private let threads: any ThreadReading
    private let pipeline: any PipelineReading
    private let policy: FollowUpPolicy

    public init(threads: any ThreadReading, pipeline: any PipelineReading, policy: FollowUpPolicy) {
        self.threads = threads
        self.pipeline = pipeline
        self.policy = policy
    }

    /// `silenceDays` may override the policy for an ad-hoc scan; defaults to the policy value if nil.
    public func staleThreads(olderThan silenceDays: Double? = nil, now: Date) throws -> [StaleThread] {
        let silence = silenceDays ?? policy.silenceDays
        var result: [StaleThread] = []
        for deal in try pipeline.all().filter({ $0.stage.isOpen }) {
            let messages = try threads.thread(id: deal.threadId)   // date ascending
            guard let last = messages.last else { continue }       // empty thread → skip
            guard Self.isStale(lastMessage: last, deal: deal, silenceDays: silence,
                               cooldownDays: policy.cooldownDays, now: now) else { continue }
            result.append(StaleThread(threadId: deal.threadId, lastUserMessage: last, deal: deal))
        }
        return result
    }

    /// PURE predicate, reused by the agent's wakesFor. A thread is stale when:
    /// • the last message is FROM the user (we're waiting on them, not the reverse),
    /// • that message is older than `silenceDays`, AND
    /// • the deal's cooldown has elapsed (never touched, or touched > cooldownDays ago).
    public static func isStale(
        lastMessage: Message, deal: Deal,
        silenceDays: Double, cooldownDays: Double, now: Date
    ) -> Bool {
        guard deal.stage.isOpen else { return false }
        guard lastMessage.isFromUser else { return false }
        let silentFor = now.timeIntervalSince(lastMessage.date)
        guard silentFor > silenceDays * 86_400 else { return false }
        
        let touched = deal.lastTouch
        guard now.timeIntervalSince(touched) > cooldownDays * 86_400 else { return false }
        
        return true
    }
}
