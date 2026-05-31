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

    // Finding 3: BookingAgent's category MUST be the canonical Triage label, not bare "Booking".
    @Test func categoryIsTheCanonicalTriageLabel() {
        #expect(BookingAgent.category == TriageCategory.booking.label)
        #expect(BookingAgent.category == "Senani/Category/Booking")
    }

    // Finding 3: a message carrying ONLY the real triage label "Senani/Category/Booking" (and no
    // meeting keywords) wakes the agent. Before the fix it checked bare "Booking" and stayed asleep.
    @Test func wakesForRealTriageBookingLabelWithoutKeywords() {
        let m = Message(id: "m-triaged", from: "sarah@client.com", to: [BK.account],
                        subject: "Re: project", body: "Sounds good, thanks.",
                        hasAttachment: false, listUnsubscribeHeader: nil,
                        labels: [TriageCategory.booking.label], threadId: "t9",
                        date: BK.now, isFromUser: false)
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
                        labels: [TriageCategory.booking.label], threadId: "t1", date: BK.now, isFromUser: true)
        #expect(agent().wakesFor(m, context: BK.context(m)) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "booking")
        #expect(a.autonomy == .prepare)   // outbound reply still ALWAYS queues regardless
    }
}
