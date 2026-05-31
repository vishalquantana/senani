import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct BookingWakesForTests {
    private func agent() -> BookingAgent {
        BookingAgent(availability: FakeAvailabilityProvider(busy: []), generator: nil, timeZone: BK.utc)
    }

    @Test func wakesForBookingLabeledMessage() {
        let m = BK.bookingLabeled()
        #expect(agent().wakesFor(m, context: BK.context(m)) == true)
    }

    @Test func wakesForMeetingIntentWithoutLabel() {
        let m = BK.meetingIntent()
        #expect(agent().wakesFor(m, context: BK.context(m)) == true)
    }

    @Test func doesNotWakeForUnrelatedMessage() {
        let m = BK.unrelated()
        #expect(agent().wakesFor(m, context: BK.context(m)) == false)
    }

    @Test func doesNotWakeForMessageFromTheUser() {
        // A Booking-labeled message we ourselves sent must not trigger a self-reply.
        let m = Message(id: "mine", from: BK.account, to: ["sarah@client.com"], subject: "Can we meet?",
                        body: "When works?", hasAttachment: false, listUnsubscribeHeader: nil,
                        labels: ["Booking"], threadId: "t1", date: BK.now, isFromUser: true)
        #expect(agent().wakesFor(m, context: BK.context(m)) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "booking")
        #expect(a.autonomy == .prepare)   // outbound reply still ALWAYS queues regardless
    }
}
