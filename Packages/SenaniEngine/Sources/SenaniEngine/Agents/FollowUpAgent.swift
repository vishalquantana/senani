import Foundation
import SenaniRules
import SenaniInference

/// Phase-3 Follow-up agent. For threads on an OPEN deal where the user's last message has gone
/// unanswered longer than the silence window (and the deal's cooldown has elapsed), it drafts a
/// voice-matched follow-up NUDGE and proposes ONE reply Action back into the thread.
///
/// The proposed Action is `Action.reply` (`actionClass == .outbound`), so the Orchestrator's
/// `ActionRouter.route` ALWAYS yields `.queuedForApproval` — it is NEVER auto-sent. When a nudge is
/// queued the agent stamps `Deal.lastTouch = context.now` via `PipelineTouching.upsert`, and the 
/// per-deal cooldown (checked through the same staleness predicate) prevents duplicate nudges.
public struct FollowUpAgent: Agent {
    public let id = "follow-up"
    /// `.prepare` is the per-agent dial; irrelevant to safety because the emitted action is outbound
    /// and `ActionRouter` queues all outbound actions regardless of autonomy.
    public let autonomy: Autonomy = .prepare

    /// Bounded generation budget for a single nudge body.
    public static let maxNudgeTokens = 320

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding
    private let pipelineRead: any PipelineReading
    private let pipelineTouch: any PipelineTouching
    private let policy: FollowUpPolicy

    public init(
        generator: any TextGenerator,
        voice: any VoicePrefixProviding,
        pipelineRead: any PipelineReading,
        pipelineTouch: any PipelineTouching,
        policy: FollowUpPolicy
    ) {
        self.generator = generator
        self.voice = voice
        self.pipelineRead = pipelineRead
        self.pipelineTouch = pipelineTouch
        self.policy = policy
    }

    /// Wakes when `message` is the last (most recent) message in its thread, is from the user, the
    /// thread sits on an open deal, and the staleness + cooldown predicate holds.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard let last = context.thread.max(by: { $0.date < $1.date }) else { return false }
        guard last.id == message.id else { return false }          // only consider the latest message
        guard let deal = (try? pipelineRead.deal(threadId: message.threadId)) ?? nil else { return false }
        return StaleThreadScanner.isStale(
            lastMessage: message, deal: deal,
            silenceDays: policy.silenceDays, cooldownDays: policy.cooldownDays, now: context.now
        )
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }
        guard var deal = try pipelineRead.deal(threadId: message.threadId) else { return [] }

        let recipient = deal.contactEmail                       // nudge goes to the deal's contact
        let draftGoal = Self.draftGoal(for: message)
        let prefix = try await voice.voicePrefix(recipient: recipient, draftGoal: draftGoal)
        let prompt = Self.buildPrompt(
            voicePrefix: prefix,
            thread: context.thread,
            recipient: recipient
        )

        let body = try await generator.generate(prompt: prompt, maxTokens: Self.maxNudgeTokens)
        let trimmedBody = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Record the touch ONLY when we actually queue a nudge.
        deal.lastTouch = context.now
        try pipelineTouch.upsert(deal)
        return [tools.followUpReply(to: message, body: trimmedBody)]
    }

    // MARK: - Prompt assembly (pure, static)

    static func draftGoal(for message: Message) -> String {
        let subject = message.subject.isEmpty ? "this conversation" : message.subject
        return "Write a polite follow-up nudge about \"\(subject)\""
    }

    static func buildPrompt(voicePrefix: String, thread: [Message], recipient: String) -> String {
        var lines: [String] = []
        lines.append(voicePrefix)
        lines.append("")
        lines.append("THREAD (oldest first):")
        let ordered = thread.sorted { $0.date < $1.date }
        for m in ordered {
            let who = m.isFromUser ? "Me" : m.from
            lines.append("From: \(who)")
            if !m.subject.isEmpty { lines.append("Subject: \(m.subject)") }
            lines.append(m.body)
            lines.append("---")
        }
        lines.append("")
        lines.append("Write a brief, polite follow-up nudge to \(recipient) — we have not heard back. "
            + "Reference the conversation, keep it short, and write only the reply body in my voice. "
            + "Do not include headers or a subject line.")
        return lines.joined(separator: "\n")
    }
}
