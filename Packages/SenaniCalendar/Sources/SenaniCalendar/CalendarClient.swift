import Foundation
import SenaniGmail

/// The Google Calendar connector, mirroring `SenaniGmail.GmailSync`: it runs over the injected
/// `HTTPClient` + `AccessTokenProviding` (reused from SenaniGmail), so the same OAuth token (with
/// the added Calendar scope) drives both connectors. Pure transport + decode; no business logic.
public struct CalendarClient: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding
    private let calendarId: String

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, calendarId: String = "primary") {
        self.http = http
        self.tokenProvider = tokenProvider
        self.calendarId = calendarId
    }

    /// Busy intervals over the window (across the configured calendar).
    public func freeBusy(range: DateRange) async throws -> [FreeBusyInterval] {
        let token = try await tokenProvider.validAccessToken()
        let request = CalendarEndpoints.freeBusy(range: range, calendarIds: [calendarId], accessToken: token)
        let (data, response) = try await http.send(request)
        try CalendarHTTP.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(FreeBusyResponse.self, from: data)
        let busy = decoded.calendars?[calendarId]?.busy ?? []
        return busy.compactMap { block in
            guard let start = CalendarHTTP.date(from: block.start),
                  let end = CalendarHTTP.date(from: block.end) else { return nil }
            return FreeBusyInterval(start: start, end: end)
        }
    }

    /// Timed events over the window. All-day events (no `dateTime`) are skipped.
    public func listEvents(range: DateRange) async throws -> [CalendarEvent] {
        let token = try await tokenProvider.validAccessToken()
        let request = CalendarEndpoints.listEvents(range: range, calendarId: calendarId, accessToken: token)
        let (data, response) = try await http.send(request)
        try CalendarHTTP.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(EventsListResponse.self, from: data)
        return (decoded.items ?? []).compactMap { item in
            guard let id = item.id,
                  let startString = item.start?.dateTime,
                  let endString = item.end?.dateTime,
                  let start = CalendarHTTP.date(from: startString),
                  let end = CalendarHTTP.date(from: endString) else { return nil }
            return CalendarEvent(id: id, title: item.summary ?? "", start: start, end: end)
        }
    }

    /// Builds a tentative-hold draft AND the `URLRequest` that WOULD create it — but does NOT send it.
    /// Phase 2 has no SenaniRules.Action to route a hold through (§5), so the actual insert is deferred.
    /// Returned for a future iteration once a `.calendarHold` Action is added with human sign-off.
    public func proposeHold(
        slot: CalendarSlot,
        title: String,
        calendarId overrideCalendarId: String? = nil
    ) async throws -> (draft: TentativeHoldDraft, request: URLRequest) {
        let token = try await tokenProvider.validAccessToken()
        let cal = overrideCalendarId ?? calendarId
        let draft = TentativeHoldDraft(calendarId: cal, title: title, start: slot.start, end: slot.end)
        let request = CalendarEndpoints.insertTentativeEvent(draft: draft, accessToken: token)
        return (draft, request)   // ⚠ intentionally not sent — see §5 deferral
    }
}
