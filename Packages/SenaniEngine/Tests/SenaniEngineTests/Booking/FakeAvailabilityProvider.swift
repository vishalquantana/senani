import Testing
import Foundation
@testable import SenaniEngine
import SenaniCalendar
import SenaniGmail

/// Recording fake: returns canned busy intervals and records the query window it was asked.
final class FakeAvailabilityProvider: AvailabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let busy: [FreeBusyInterval]
    private var windows: [DateRange] = []

    init(busy: [FreeBusyInterval]) { self.busy = busy }

    func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval] {
        _record(range)
        return busy
    }
    
    private func _record(_ range: DateRange) {
        lock.lock(); defer { lock.unlock() }
        windows.append(range)
    }

    var recordedWindows: [DateRange] { lock.lock(); defer { lock.unlock() }; return windows }
}

@Suite struct AvailabilityProvidingTests {
    @Test func fakeReturnsCannedBusyAndRecordsWindow() async throws {
        let start = CalendarHTTP.date(from: "2023-11-15T09:00:00Z")!
        let busy = [FreeBusyInterval(start: start, end: start.addingTimeInterval(3_600))]
        let fake = FakeAvailabilityProvider(busy: busy)
        let window = DateRange(start: start, end: start.addingTimeInterval(86_400))
        let out = try await fake.busyIntervals(in: window)
        #expect(out == busy)
        let windows = fake.recordedWindows
        #expect(windows.count == 1)
    }

    @Test func calendarClientAdapterConformsAndForwardsToFreeBusy() async throws {
        // Compile + behavior guarantee that the production adapter wraps the real CalendarClient.
        let http = FakeCalHTTP()
        await http.enqueueFreeBusy()
        let client = CalendarClient(http: http, tokenProvider: StubCalToken(token: "T"))
        let adapter = CalendarAvailabilityProvider(client: client)
        let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!
        let out = try await adapter.busyIntervals(in: DateRange(start: start, end: start.addingTimeInterval(86_400)))
        #expect(out.count == 1)
    }
}

/// Minimal local fakes (SenaniGmail/SenaniCalendar ship no public fakes for the engine test target).
actor FakeCalHTTP: HTTPClient {
    private var queue: [(Data, HTTPURLResponse)] = []
    func enqueueFreeBusy() {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!
        let json = #"{"calendars":{"primary":{"busy":[{"start":"2023-11-15T09:00:00Z","end":"2023-11-15T10:00:00Z"}]}}}"#
        queue.append((Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        return queue.removeFirst()
    }
}

struct StubCalToken: AccessTokenProviding {
    let token: String
    func validAccessToken() async throws -> String { token }
}
