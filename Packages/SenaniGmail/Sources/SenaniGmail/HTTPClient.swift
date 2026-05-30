import Foundation

public enum HTTPClientError: Error, Equatable {
    case noQueuedResponse
    case nonHTTPResponse
    case unexpectedStatus(Int, body: String)
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
