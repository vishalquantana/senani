import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniCalendar
import SenaniInference

@Suite struct BookingProposalsTests {
    private func agent(busy: [FreeBusyInterval], generator: (any TextGenerator)? = nil) -> BookingAgent {
        BookingAgent(availability: FakeAvailabilityProvider(busy: busy),
                     generator: generator,
                     timeZone: BK.utc)
    }

    @Test func emitsExactlyOneOutboundReplyProposingThreeSlots() async throws {
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()

        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: tools(FakeTextGenerator()))

        #expect(actions.count == 1)
        #expect(actions.first?.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
        // It is a .reply (via tools.draftReply) carrying all three slot times.
        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.contains("10:00"))
        #expect(body.contains("10:30"))
        #expect(body.contains("11:00"))
        // The seam was queried for a forward window starting at `now`.
        let windows = provider.recordedWindows
        #expect(windows.first?.start == BK.now)
    }

    @Test func neverBooksAndNeverAutoSends() async throws {
        // The agent returns only an outbound reply; it builds no hold and performs no calendar write.
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: tools(FakeTextGenerator()))
        // Exactly one action, and it is outbound (queues) — no executed side effect, no .runAgent, no insert.
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { $0.actionClass == .outbound })
    }

    @Test func returnsNoProposalsForNonBookingMessage() async throws {
        let provider = FakeAvailabilityProvider(busy: [])
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.unrelated()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: tools(FakeTextGenerator()))
        #expect(actions.isEmpty)
        // The seam was never queried (no wasted availability fetch).
        let windows = provider.recordedWindows
        #expect(windows.isEmpty)
    }

    @Test func fallsBackToAskingForAvailabilityWhenNoSlotsFree() async throws {
        // Whole week busy → no slots → still ONE outbound reply, asking the sender for their availability.
        let busyWeek = (0..<7).map { day -> FreeBusyInterval in
            let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!.addingTimeInterval(Double(day) * 86_400)
            return FreeBusyInterval(start: start, end: start.addingTimeInterval(86_400))
        }
        let provider = FakeAvailabilityProvider(busy: busyWeek)
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: tools(FakeTextGenerator()))
        #expect(actions.count == 1)
        #expect(actions.first?.actionClass == .outbound)
        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.lowercased().contains("availability"))
    }

    @Test func usesGeneratorToPolishWhenProvidedAndThreadsSlotsIntoPrompt() async throws {
        let gen = FakeTextGenerator(response: "Happy to meet! Here are some times that work for me.")
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: gen, timeZone: BK.utc)
        let m = BK.bookingLabeled()

        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: tools(gen))

        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.contains("Happy to meet"))      // generator output used
        let prompts = await gen.recordedPrompts
        let prompt = try #require(prompts.last)
        #expect(prompt.contains("10:00"))            // the chosen slots were given to the model
    }
}
