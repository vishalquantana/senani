import Foundation

/// Request builders for the Google Calendar v3 API, mirroring `SenaniGmail.GmailEndpoints`.
/// Pure: each returns a `URLRequest` with the Bearer header set; none performs I/O.
public enum CalendarEndpoints {
    static let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// POST /freeBusy — busy intervals for the given calendars over [start, end).
    public static func freeBusy(
        range: DateRange,
        calendarIds: [String],
        accessToken: String
    ) -> URLRequest {
        var request = authorizedRequest(url: baseURL.appendingPathComponent("freeBusy"),
                                        method: "POST", accessToken: accessToken)
        setJSONBody([
            "timeMin": CalendarHTTP.timestamp(range.start),
            "timeMax": CalendarHTTP.timestamp(range.end),
            "items": calendarIds.map { ["id": $0] },
        ], on: &request)
        return request
    }

    /// GET /calendars/{id}/events — single (expanded) events over [start, end), ordered by start.
    public static func listEvents(
        range: DateRange,
        calendarId: String,
        accessToken: String
    ) -> URLRequest {
        let path = "calendars/\(calendarId)/events"
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: CalendarHTTP.timestamp(range.start)),
            URLQueryItem(name: "timeMax", value: CalendarHTTP.timestamp(range.end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
        ]
        return authorizedRequest(url: comps.url!, method: "GET", accessToken: accessToken)
    }

    /// POST /calendars/{id}/events — builds (does NOT send) a tentative hold insert.
    /// Used only by `CalendarClient.proposeHold` for a FUTURE iteration (§5); not routed in Phase 2.
    public static func insertTentativeEvent(
        draft: TentativeHoldDraft,
        accessToken: String
    ) -> URLRequest {
        let path = "calendars/\(draft.calendarId)/events"
        var request = authorizedRequest(url: baseURL.appendingPathComponent(path),
                                        method: "POST", accessToken: accessToken)
        setJSONBody([
            "summary": draft.title,
            "status": "tentative",
            "transparency": "opaque",
            "start": ["dateTime": CalendarHTTP.timestamp(draft.start)],
            "end": ["dateTime": CalendarHTTP.timestamp(draft.end)],
        ], on: &request)
        return request
    }

    private static func authorizedRequest(url: URL, method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func setJSONBody(_ object: [String: Any], on request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Response DTOs (decoded inside CalendarClient)

struct FreeBusyResponse: Decodable {
    var calendars: [String: FreeBusyCalendar]?
}

struct FreeBusyCalendar: Decodable {
    var busy: [FreeBusyBusy]?
    var errors: [FreeBusyError]?
}

struct FreeBusyError: Decodable, Equatable {
    var domain: String?
    var reason: String?
}

struct FreeBusyBusy: Decodable {
    var start: String
    var end: String
}

struct EventsListResponse: Decodable {
    var items: [EventItem]?
}

struct EventItem: Decodable {
    var id: String?
    var summary: String?
    var start: EventDateTime?
    var end: EventDateTime?
}

struct EventDateTime: Decodable {
    var dateTime: String?
    var date: String?   // all-day events use `date` instead of `dateTime`
}
