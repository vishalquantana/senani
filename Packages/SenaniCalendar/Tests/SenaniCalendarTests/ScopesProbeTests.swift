import Testing
@testable import SenaniCalendar
import SenaniGmail
import SenaniRules

@Test func packageLinksGmailSeamsAndDeclaresCalendarScopes() {
    // Proves the package builds, links SenaniGmail (HTTPClient seam) + SenaniRules.
    let _: any HTTPClient.Type = URLSessionHTTPClient.self
    let action: SenaniRules.Action = .reply(body: "x")
    #expect(action.actionClass == .outbound)
    #expect(CalendarScopes.all.contains("https://www.googleapis.com/auth/calendar.readonly"))
    #expect(CalendarScopes.all.contains("https://www.googleapis.com/auth/calendar.events"))
}
