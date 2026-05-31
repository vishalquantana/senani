import Foundation
import SenaniRules

/// A single proposed outreach draft: an OUTBOUND `Action.send(body:)` paired with a synthesized
/// outbound `Message` that carries the recipient + subject (the frozen `Action` model has no
/// compose-new-message payload — see the plan's §8 escalation for a dedicated `.compose` case).
/// `Action.send` is `actionClass == .outbound`, so `ActionRouter.route` ALWAYS queues it for
/// approval — outreach is NEVER auto-sent.
public struct OutreachProposal: Sendable, Equatable {
    public let message: Message     // synthesized: from=account, to=[contact], isFromUser=true, subject/body set
    public let action: Action       // .send(body:) — outbound → always queues

    public init(message: Message, action: Action) {
        self.message = message
        self.action = action
    }

    /// Builds the proposal for a new outbound message to `contact`.
    public static func make(
        account: String,
        contact: String,
        subject: String,
        body: String,
        now: Date
    ) -> OutreachProposal {
        // A deterministic, unique thread/message id for a brand-new conversation.
        let stamp = Int(now.timeIntervalSince1970)
        let threadId = "outreach:\(contact):\(stamp)"
        let message = Message(
            id: threadId,
            from: account,
            to: [contact],
            subject: subject,
            body: body,
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: [],
            threadId: threadId,
            date: now,
            isFromUser: true
        )
        return OutreachProposal(message: message, action: .send(body: body))
    }
}
