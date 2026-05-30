import SenaniRules

public func replyZeroRule(id: String = "builtin.reply-zero") -> Rule {
    Rule(
        id: id,
        name: "Reply Zero",
        enabled: true,
        conditions: Conditions(
            mode: .all,
            structured: [],
            aiPredicate: "Thread needs a reply from me"
        ),
        actions: [.flagNeedsReply],
        autonomy: .auto,
        runOn: .incoming
    )
}
