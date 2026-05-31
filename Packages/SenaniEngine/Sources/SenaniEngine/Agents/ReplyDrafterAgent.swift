import Foundation
import SenaniRules
import SenaniInference

public struct ReplyDrafterAgent: Agent {
    public let id = "reply-drafter"
    public let autonomy: Autonomy = .prepare

    /// Category routing (Finding 9): reply-drafting is signal-driven (`context.needsReply`), not bound
    /// to a single category, so it subscribes to all of them and lets `wakesFor` gate firing.
    public var categories: Set<String> { TriageCategory.allLabels }

    public static let maxDraftTokens = 512

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding

    public init(generator: any TextGenerator, voice: any VoicePrefixProviding) {
        self.generator = generator
        self.voice = voice
    }

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        context.needsReply && !message.isFromUser
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        let recipient = message.from
        let draftGoal = Self.draftGoal(for: message)
        let prefix = try await voice.voicePrefix(recipient: recipient, draftGoal: draftGoal)
        let prompt = Self.buildPrompt(
            voicePrefix: prefix,
            thread: context.thread,
            incoming: message,
            account: context.account
        )

        let body = try await generator.generate(prompt: prompt, maxTokens: Self.maxDraftTokens)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return [tools.draftReply(to: message, body: trimmed)]
    }

    static func draftGoal(for message: Message) -> String {
        let subject = message.subject.isEmpty ? "this email" : message.subject
        return "Draft a reply to \"\(subject)\""
    }

    static func buildPrompt(voicePrefix: String, thread: [Message], incoming: Message, account: String) -> String {
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
        lines.append("Draft a reply to the latest message from \(incoming.from). "
            + "Write only the reply body, in my voice. Do not include headers or a subject line.")
        return lines.joined(separator: "\n")
    }
}
