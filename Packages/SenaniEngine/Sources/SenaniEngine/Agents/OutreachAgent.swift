import Foundation
import SenaniRules
import SenaniInference

/// Phase-3 Outreach agent. **List-driven, user-initiated** (not inbound-message-triggered):
/// the user (or the Scheduler's daily dormant-deal hook) hands it a list of target contacts,
/// and it generates a personalized, voice-conditioned cold/warm draft per eligible target.
/// Each draft is an OUTBOUND `Action.send` (always queues for approval — never auto-sent),
/// gated by a per-contact cooldown + per-run cap.
public struct OutreachAgent: Agent {
    public let id = "outreach"
    public let autonomy: Autonomy = .ask

    public static let maxDraftTokens = 384

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding
    private let policy: OutreachPolicy

    public init(generator: any TextGenerator,
                voice: any VoicePrefixProviding,
                policy: OutreachPolicy = OutreachPolicy()) {
        self.generator = generator
        self.voice = voice
        self.policy = policy
    }

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool { false }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        []
    }

    public func outreach(
        to targets: [OutreachTarget],
        context: AgentContext,
        tools: AgentTools
    ) async throws -> [OutreachProposal] {
        let eligible = policy.eligible(from: targets, now: context.now)
        var proposals: [OutreachProposal] = []
        for target in eligible {
            let draftGoal = Self.draftGoal(for: target)
            let prefix = try await voice.voicePrefix(recipient: target.contactEmail, draftGoal: draftGoal)
            let prompt = Self.buildPrompt(voicePrefix: prefix, target: target, account: context.account)
            let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxDraftTokens)
            let body = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let subject = Self.subject(for: target)
            proposals.append(OutreachProposal.make(
                account: context.account, contact: target.contactEmail,
                subject: subject, body: body, now: context.now))
        }
        return proposals
    }

    static let openStages: Set<DealStage> = [.lead, .qualified, .proposal, .negotiation]

    public func dormantTargets(in store: any PipelineStore, now: Date) throws -> [OutreachTarget] {
        let cooldown = policy.cooldownDays * 86_400
        let allDeals = try store.all()
        let openDeals = allDeals.filter { Self.openStages.contains($0.stage) }
        let dormant = openDeals.filter { deal in
            let touched = deal.lastTouch
            return now.timeIntervalSince(touched) >= cooldown
        }
        let sorted = dormant.sorted { $0.lastTouch < $1.lastTouch }
        return sorted.map { OutreachTarget(contactEmail: $0.contactEmail, deal: $0, thread: []) }
    }

    static func draftGoal(for target: OutreachTarget) -> String {
        if let company = target.deal?.company {
            return "Write a warm outreach email to a contact at \(company)"
        }
        return "Write a cold outreach email to a new prospect"
    }

    static func subject(for target: OutreachTarget) -> String {
        if let company = target.deal?.company {
            return "Following up — \(company)"
        }
        return "Quick introduction"
    }

    static func buildPrompt(voicePrefix: String, target: OutreachTarget, account: String) -> String {
        var lines: [String] = []
        lines.append(voicePrefix)
        lines.append("")
        if let deal = target.deal {
            lines.append("CONTEXT (existing relationship):")
            if let company = deal.company { lines.append("Company: \(company)") }
            lines.append("Pipeline stage: \(deal.stage.rawValue)")
            if let score = deal.score { lines.append("Lead score: \(score)") }
            lines.append("")
        }
        if !target.thread.isEmpty {
            lines.append(PromptFencing.preamble)
            lines.append("")
            lines.append("PRIOR THREAD (oldest first):")
            for m in target.thread.sorted(by: { $0.date < $1.date }) {
                let who = m.isFromUser ? "Me" : m.from
                lines.append("From: \(who)")
                lines.append(PromptFencing.fence("BODY", m.body))
                lines.append("---")
            }
            lines.append("")
        }
        if target.isWarm {
            lines.append("Write a warm, personalized outreach email to \(target.contactEmail). "
                + "Reference our existing relationship. Write only the email body, in my voice. "
                + "Do not include headers or a subject line.")
        } else {
            lines.append("Write a cold, personalized outreach email to \(target.contactEmail). "
                + "Keep it short and respectful. Write only the email body, in my voice. "
                + "Do not include headers or a subject line.")
        }
        return lines.joined(separator: "\n")
    }
}
