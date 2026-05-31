import Foundation
@testable import SenaniCalendar
import SenaniGmail

/// Local HTTP fake mirroring SenaniGmail's FakeHTTPClient (SenaniGmail ships no public fakes).
actor FakeHTTPClient: HTTPClient {
    struct Queued { let data: Data; let response: HTTPURLResponse }
    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueueJSON(_ json: String, status: Int = 200,
                     url: URL = URL(string: "https://www.googleapis.com/calendar/v3")!) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        queue.append(Queued(data: Data(json.utf8), response: response))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }
}

struct StubTokenProvider: AccessTokenProviding {
    let token: String
    func validAccessToken() async throws -> String { token }
}

enum CalFix {
    /// Two busy blocks on the primary calendar.
    static let freeBusyJSON = """
    {"calendars":{"primary":{"busy":[
      {"start":"2023-11-15T09:00:00Z","end":"2023-11-15T10:00:00Z"},
      {"start":"2023-11-15T13:00:00Z","end":"2023-11-15T14:00:00Z"}
    ]}}}
    """

    /// One timed event + one all-day event (all-day uses `date`, no `dateTime`).
    static let eventsJSON = """
    {"items":[
      {"id":"e1","summary":"Standup","start":{"dateTime":"2023-11-15T09:00:00Z"},"end":{"dateTime":"2023-11-15T09:30:00Z"}},
      {"id":"e2","summary":"Holiday","start":{"date":"2023-11-16"},"end":{"date":"2023-11-17"}}
    ]}
    """
}
