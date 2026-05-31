import Testing
import Foundation
@testable import SenaniCalendar
import SenaniGmail

private func range() -> DateRange {
    let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!
    return DateRange(start: start, end: start.addingTimeInterval(7 * 86_400))
}

@Test func freeBusyParsesBusyIntervals() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.freeBusyJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))

    let busy = try await client.freeBusy(range: range())

    #expect(busy.count == 2)
    #expect(busy.first?.start == CalendarHTTP.date(from: "2023-11-15T09:00:00Z"))
    #expect(busy.first?.end == CalendarHTTP.date(from: "2023-11-15T10:00:00Z"))
    // The request carried the Bearer token.
    let sent = await http.recordedRequests
    #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer T")
}

@Test func listEventsParsesTimedEventsAndSkipsAllDayWithoutDateTime() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.eventsJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))

    let events = try await client.listEvents(range: range())

    // The all-day event (no dateTime) is dropped; only the timed event remains.
    #expect(events.map(\.id) == ["e1"])
    #expect(events.first?.title == "Standup")
}

@Test func freeBusyThrowsOnPerCalendarErrorsInsteadOfReadingFree() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.freeBusyErrorJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    // A per-calendar `errors` payload must THROW, never silently return [] ("fully free").
    await #expect(throws: CalendarError.self) {
        _ = try await client.freeBusy(range: range())
    }
}

@Test func freeBusyResolvesWhenResponseKeyedUnderResolvedAddress() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.freeBusyResolvedKeyJSON)
    // Requested id is "primary" but the response keys under the resolved address.
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    let busy = try await client.freeBusy(range: range())
    #expect(busy.count == 1)
    #expect(busy.first?.start == CalendarHTTP.date(from: "2023-11-15T09:00:00Z"))
}

@Test func freeBusyThrowsOnHTTPError() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"error":"forbidden"}"#, status: 403)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    await #expect(throws: HTTPClientError.self) {
        _ = try await client.freeBusy(range: range())
    }
}

@Test func proposeHoldBuildsDraftAndRequestButDoesNotSend() async throws {
    let http = FakeHTTPClient()   // nothing enqueued — proving no request is sent
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    let start = CalendarHTTP.date(from: "2023-11-15T11:00:00Z")!
    let slot = CalendarSlot(start: start, end: start.addingTimeInterval(1_800))

    let (draft, request) = try await client.proposeHold(slot: slot, title: "Hold: Sarah", calendarId: "primary")

    #expect(draft.title == "Hold: Sarah")
    #expect(draft.start == start)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    // CRITICAL: proposeHold NEVER hits the network in Phase 2.
    let sent = await http.recordedRequests
    #expect(sent.isEmpty)
}
