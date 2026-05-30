import SenaniRules

public struct ReplyZeroService: Sendable {
    private let classifier: NeedsReplyClassifier
    private let store: NeedsReplyStore
    private let accountEmail: String
    private let confirmer: (any PredicateEvaluator)?

    public init(
        classifier: NeedsReplyClassifier = NeedsReplyClassifier(),
        store: NeedsReplyStore,
        accountEmail: String,
        confirmer: (any PredicateEvaluator)? = nil
    ) {
        self.classifier = classifier
        self.store = store
        self.accountEmail = accountEmail
        self.confirmer = confirmer
    }

    public func scan(threads: [String: [Message]]) async throws {
        for (threadId, messages) in threads {
            if await classifier.classify(thread: messages, accountEmail: accountEmail, confirmer: confirmer),
               let last = messages.sorted(by: { $0.date < $1.date }).last {
                try store.set(threadId: threadId, messageId: last.id)
            } else {
                try store.clear(threadId: threadId)
            }
        }
    }

    public func needsYou() throws -> [NeedsReplyFlag] {
        try store.pending()
    }

    public func count() throws -> Int {
        try store.count()
    }
}
