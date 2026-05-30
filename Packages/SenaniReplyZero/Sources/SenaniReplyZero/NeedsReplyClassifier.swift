import Foundation
import SenaniRules

public struct NeedsReplyClassifier: Sendable {
    public init() {}

    public func classify(thread: [Message], accountEmail: String) -> Bool {
        guard let last = thread.sorted(by: { $0.date < $1.date }).last else {
            return false
        }
        guard !last.isFromUser else {
            return false
        }
        guard thread.contains(where: { message in
            message.to.contains { $0.caseInsensitiveCompare(accountEmail) == .orderedSame }
        }) else {
            return false
        }
        return Self.containsAsk(last.subject) || Self.containsAsk(last.body)
    }

    public func classify(
        thread: [Message],
        accountEmail: String,
        confirmer: (any PredicateEvaluator)?
    ) async -> Bool {
        guard classify(thread: thread, accountEmail: accountEmail),
              let last = thread.sorted(by: { $0.date < $1.date }).last
        else {
            return false
        }
        guard let confirmer else {
            return true
        }
        let results = await confirmer.evaluate(
            predicates: ["Does this email require a reply from the user?"],
            against: last
        )
        return results.first == true
    }

    private static func containsAsk(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("?") {
            return true
        }
        let phrases = [
            "could you", "can you", "please send", "please provide", "let me know",
            "do you", "are you", "would you", "need your", "waiting for",
        ]
        return phrases.contains { lowered.contains($0) }
    }
}
