import Foundation
import SenaniGmail

/// Errors surfaced by `CalendarClient` for conditions that must NOT be silently treated as "free".
public enum CalendarError: Error, Equatable {
    /// The freeBusy API returned a per-calendar `errors` payload (e.g. notFound/forbidden) instead of
    /// `busy`. Treating this as zero busy would risk DOUBLE-BOOKING, so we surface it.
    case freeBusyLookupFailed(calendarId: String, errors: [String])
    /// The freeBusy response carried no entry we could resolve for the requested calendar.
    case freeBusyCalendarMissing(calendarId: String)
}

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
        let calendars = decoded.calendars ?? [:]
        // Robust key lookup: Google may key the result under a RESOLVED address (e.g. the calendar's
        // real email) rather than the requested id. Prefer the requested id; fall back to the sole
        // entry when exactly one is returned.
        let entry = calendars[calendarId] ?? (calendars.count == 1 ? calendars.values.first : nil)
        guard let calendar = entry else {
            throw CalendarError.freeBusyCalendarMissing(calendarId: calendarId)
        }
        // A per-calendar `errors` payload means the lookup FAILED — never read it as "fully free".
        if let errors = calendar.errors, !errors.isEmpty {
            let reasons = errors.map { $0.reason ?? $0.domain ?? "unknown" }
            throw CalendarError.freeBusyLookupFailed(calendarId: calendarId, errors: reasons)
        }
        let busy = calendar.busy ?? []
        return busy.compactMap { block in
            guard let start = CalendarHTTP.date(from: block.start),
                  let end = CalendarHTTP.date(from: block.end) else { return nil }
            return FreeBusyInterval(start: start, end: end)
        }
    }

    /// Timed events over the window. All-day events (no `dateTime`) are skipped.
    /// Paginates the events.list endpoint (mirrors `GmailSync.fetchMessages`): without the loop,
    /// a truncated first page would make later busy windows look free.
    public func listEvents(range: DateRange, maxResults: Int = 250) async throws -> [CalendarEvent] {
        let token = try await tokenProvider.validAccessToken()
        var pageToken: String?
        var events: [CalendarEvent] = []

        repeat {
            let request = CalendarEndpoints.listEvents(
                range: range,
                calendarId: calendarId,
                pageToken: pageToken,
                maxResults: maxResults,
                accessToken: token
            )
            let (data, response) = try await http.send(request)
            try CalendarHTTP.validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(EventsListResponse.self, from: data)

            events.append(contentsOf: (decoded.items ?? []).compactMap { item in
                guard let id = item.id,
                      let startString = item.start?.dateTime,
                      let endString = item.end?.dateTime,
                      let start = CalendarHTTP.date(from: startString),
                      let end = CalendarHTTP.date(from: endString) else { return nil }
                return CalendarEvent(id: id, title: item.summary ?? "", start: start, end: end)
            })
            pageToken = decoded.nextPageToken
        } while pageToken != nil

        return events
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
