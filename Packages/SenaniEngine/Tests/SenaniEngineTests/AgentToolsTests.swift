import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

private func sampleMessage() -> Message {
    Message(id: "m1", from: "a@b.com", to: ["me@x.com"], subject: "Hi", body: "Body",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000), isFromUser: false)
}

@Test func draftReplyBuildsAnOutboundReplyAction() {
    let tools = AgentTools(generator: FakeTextGenerator())
    let action = tools.draftReply(to: sampleMessage(), body: "Thanks!")
    #expect(action == .reply(body: "Thanks!"))
    #expect(action.actionClass == ActionClass.outbound)   // a draft maps to reply, which is outbound
}

@Test func proposeLabelBuildsALabelAction() {
    let tools = AgentTools(generator: FakeTextGenerator())
    #expect(tools.proposeLabel("Lead", on: sampleMessage()) == .label("Lead"))
}

@Test func archiveAndMarkReadBuildTheirActions() {
    let tools = AgentTools(generator: FakeTextGenerator())
    #expect(tools.archive(sampleMessage()) == .archive)
    #expect(tools.markRead(sampleMessage()) == .markRead)
}
