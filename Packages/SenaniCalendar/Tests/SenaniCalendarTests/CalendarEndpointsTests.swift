import Testing
import Foundation
@testable import SenaniCalendar
import SenaniGmail

@Test func freeBusyRequestIsAuthorizedPostWithTimeWindow() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
    let end = start.addingTimeInterval(7 * 86_400)
    let req = CalendarEndpoints.freeBusy(
        range: DateRange(start: start, end: end),
        calendarIds: ["primary"],
        accessToken: "TOKEN"
    )
    #expect(req.url?.absoluteString == "https://www.googleapis.com/calendar/v3/freeBusy")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
    #expect(body?["timeMin"] as? String == "2023-11-14T22:13:20Z")
    let items = body?["items"] as? [[String: Any]]
    #expect(items?.first?["id"] as? String == "primary")
}

@Test func listEventsRequestIsAuthorizedGetWithSingleEventsExpansion() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(7 * 86_400)
    let req = CalendarEndpoints.listEvents(
        range: DateRange(start: start, end: end),
        calendarId: "primary",
        accessToken: "T"
    )
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/calendar/v3/calendars/primary/events")
    #expect(req.httpMethod == "GET")
    let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(q["timeMin"] == "2023-11-14T22:13:20Z")
    #expect(q["singleEvents"] == "true")
    #expect(q["orderBy"] == "startTime")
}

@Test func insertTentativeEventRequestBuildsTransparentTentativeBody() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(1_800)
    let draft = TentativeHoldDraft(calendarId: "primary", title: "Hold: Sarah", start: start, end: end)
    let req = CalendarEndpoints.insertTentativeEvent(draft: draft, accessToken: "T")
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/calendar/v3/calendars/primary/events")
    #expect(req.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
    #expect(body?["status"] as? String == "tentative")
    #expect(body?["summary"] as? String == "Hold: Sarah")
    let startObj = body?["start"] as? [String: Any]
    #expect(startObj?["dateTime"] as? String == "2023-11-14T22:13:20Z")
}

@Test func validateThrowsGmailHTTPStatusErrorOnNon2xx() {
    let url = URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!
    let bad = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
    #expect(throws: HTTPClientError.self) {
        try CalendarHTTP.validate(response: bad, data: Data(#"{"error":"denied"}"#.utf8))
    }
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    #expect(throws: Never.self) { try CalendarHTTP.validate(response: ok, data: Data()) }
}
