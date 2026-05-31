import Foundation
import SenaniRules

/// One unit of outreach work: a contact to reach out to, with optional CRM Deal context
/// and any prior thread we have with them (empty for a true cold contact).
public struct OutreachTarget: Sendable, Equatable {
    public let contactEmail: String          // recipient email — a NEW conversation, not a reply
    public let deal: Deal?              // optional CRM deal (drives warm vs cold framing + cooldown)
    public let thread: [Message]        // prior context, if any (empty = cold)

    public init(contactEmail: String, deal: Deal? = nil, thread: [Message] = []) {
        self.contactEmail = contactEmail
        self.deal = deal
        self.thread = thread
    }

    /// Warm if we have an existing deal or prior thread; otherwise cold.
    public var isWarm: Bool { deal != nil || !thread.isEmpty }
}

/// Pure outreach gating policy: a per-contact cooldown (no repeat outreach within N days of
/// the deal's last touch) and a per-run cap (never emit more than `maxPerRun` drafts at once).
public struct OutreachPolicy: Sendable, Equatable {
    public let cooldownDays: Double
    public let maxPerRun: Int

    public init(cooldownDays: Double = 7, maxPerRun: Int = 25) {
        self.cooldownDays = cooldownDays
        self.maxPerRun = maxPerRun
    }

    /// A contact is on cooldown only if it has a deal touched within `cooldownDays` of `now`.
    public func isOnCooldown(_ target: OutreachTarget, now: Date) -> Bool {
        guard let deal = target.deal else { return false }
        let touched = deal.lastTouch
        let elapsed = now.timeIntervalSince(touched)
        return elapsed < cooldownDays * 86_400
    }

    /// Filters out cooled contacts (order preserved) then truncates to `maxPerRun`.
    public func eligible(from targets: [OutreachTarget], now: Date) -> [OutreachTarget] {
        guard maxPerRun > 0 else { return [] }
        let notCooled = targets.filter { !isOnCooldown($0, now: now) }
        return Array(notCooled.prefix(maxPerRun))
    }
}
