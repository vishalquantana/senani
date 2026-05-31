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

@Test func listEventsParsesFractionalSecondTimestamps() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.eventsFractionalJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    let events = try await client.listEvents(range: range())
    // The fractional-second event must parse and count as busy (not be compactMap-dropped).
    #expect(events.map(\.id) == ["e1"])
    #expect(events.first?.start == CalendarHTTP.date(from: "2023-11-15T09:00:00Z"))
    #expect(events.first?.end == CalendarHTTP.date(from: "2023-11-15T09:30:00Z"))
}

@Test func dateParsesBothPlainAndFractionalSeconds() {
    // Plain RFC3339 still works...
    #expect(CalendarHTTP.date(from: "2023-11-15T09:00:00Z") != nil)
    // ...and fractional/millisecond variants now parse too.
    #expect(CalendarHTTP.date(from: "2023-11-15T09:00:00.000Z") != nil)
    #expect(CalendarHTTP.date(from: "2023-11-15T09:00:00.000Z")
            == CalendarHTTP.date(from: "2023-11-15T09:00:00Z"))
}

@Test func listEventsFollowsNextPageTokenAndReturnsAllEvents() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.eventsPage1JSON)   // carries nextPageToken=PAGE2
    await http.enqueueJSON(CalFix.eventsPage2JSON)   // terminal page
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))

    let events = try await client.listEvents(range: range())

    // BOTH pages' events are returned (truncating page 1 would make page-2 busy windows look free).
    #expect(events.map(\.id) == ["e1", "e2"])
    // Two HTTP calls were made: the initial page + the nextPageToken follow-up.
    let sent = await http.recordedRequests
    #expect(sent.count == 2)
    // The follow-up request carried the pageToken (and never the previous-page token in a loop).
    let secondURL = URLComponents(url: sent[1].url!, resolvingAgainstBaseURL: false)!
    let q = Dictionary(uniqueKeysWithValues: (secondURL.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(q["pageToken"] == "PAGE2")
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
