import Testing
@testable import SenaniRules

@Suite struct ActionTests {
    @Test func reversibleActionsAreClassifiedReversible() {
        let reversible: [Action] = [
            .label("x"), .archive, .markRead, .markUnread, .star, .unstar,
            .move("Y"), .flagNeedsReply, .fileAttachment(folder: "Invoices"),
            .parseDoc, .runAgent(id: "lead"), .draft(body: "hi"),
            .localWebhook(name: "notify")
        ]
        for action in reversible {
            #expect(action.actionClass == .reversible, "\(action) should be reversible")
        }
    }

    @Test func outboundActionsAreClassifiedOutbound() {
        let outbound: [Action] = [
            .reply(body: "ok"), .forward(to: "a@b.com", body: "fyi"),
            .send(body: "hello"), .markSpam
        ]
        for action in outbound {
            #expect(action.actionClass == .outbound, "\(action) should be outbound")
        }
    }
}
