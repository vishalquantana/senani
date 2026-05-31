import Foundation
import SenaniGmail
import Testing
@testable import SenaniApp

actor FakeHTTPClient: HTTPClient {
    struct Queued: Sendable {
        let data: Data
        let status: Int
        let url: URL
    }

    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueueJSON(
        _ json: String,
        status: Int = 200,
        url: URL = URL(string: "https://oauth2.googleapis.com/token")!
    ) {
        queue.append(.init(data: Data(json.utf8), status: status, url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else {
            throw HTTPClientError.noQueuedResponse
        }
        let next = queue.removeFirst()
        let response = HTTPURLResponse(
            url: next.url,
            statusCode: next.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }
}

final class FakeBrowserOpener: BrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var openedURLs: [URL] = []

    func open(_ url: URL) {
        lock.lock()
        openedURLs.append(url)
        lock.unlock()
    }

    var opened: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedURLs
    }
}

struct FakeLoopbackCapture: LoopbackCapturing {
    let port: Int
    let result: LoopbackResult

    func boundPort() -> Int { port }
    func awaitRedirect() async throws -> LoopbackResult { result }
    func stop() {}
}

@Test func fakeHTTPClientReplaysAndRecords() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"ok":true}"#)
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"

    let (data, response) = try await http.send(request)

    #expect(response.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    #expect(await http.recordedRequests.count == 1)
}
