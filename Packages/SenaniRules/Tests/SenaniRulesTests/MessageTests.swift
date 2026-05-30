import Testing
import Foundation
@testable import SenaniRules

@Suite struct MessageTests {
    @Test func senderDomainIsLowercasedHostAfterAt() {
        let m = Message(
            id: "1", from: "Alice@Example.COM", to: ["me@acme.io"],
            subject: "Hi", body: "hello", hasAttachment: false,
            listUnsubscribeHeader: nil, labels: [], threadId: "t1",
            date: Date(timeIntervalSince1970: 0), isFromUser: false
        )
        #expect(m.senderDomain == "example.com")
    }

    @Test func senderDomainEmptyWhenNoAt() {
        let m = Message(
            id: "2", from: "garbage", to: [], subject: "", body: "",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(timeIntervalSince1970: 0), isFromUser: false
        )
        #expect(m.senderDomain == "")
    }
}
