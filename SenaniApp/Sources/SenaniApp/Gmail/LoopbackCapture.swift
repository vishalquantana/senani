import Foundation

public struct LoopbackResult: Sendable, Equatable {
    public let code: String?
    public let state: String?
    public let error: String?

    public init(code: String?, state: String?, error: String?) {
        self.code = code
        self.state = state
        self.error = error
    }
}

public protocol LoopbackCapturing: Sendable {
    func boundPort() -> Int
    func awaitRedirect() async throws -> LoopbackResult
    func stop()
}

public enum LoopbackRedirectParser {
    public static func parse(requestLine: String) -> LoopbackResult {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return LoopbackResult(code: nil, state: nil, error: nil)
        }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            return LoopbackResult(code: nil, state: nil, error: nil)
        }

        let queryItems = components.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })
        return LoopbackResult(
            code: values["code"] ?? nil,
            state: values["state"] ?? nil,
            error: values["error"] ?? nil
        )
    }
}

#if canImport(Network)
import Network

public final class NWLoopbackListener: LoopbackCapturing, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "senani.oauth.loopback")

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.start(queue: queue)
    }

    public func boundPort() -> Int {
        guard let port = listener.port?.rawValue else { return 0 }
        return Int(port)
    }

    public func awaitRedirect() async throws -> LoopbackResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    connection.start(queue: self.queue)
                    self.receiveRedirect(from: connection, continuation: continuation)
                }
            }
        } onCancel: {
            stop()
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func receiveRedirect(
        from connection: NWConnection,
        continuation: CheckedContinuation<LoopbackResult, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, error in
            if let error {
                connection.cancel()
                continuation.resume(throwing: error)
                return
            }

            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let result = LoopbackRedirectParser.parse(requestLine: firstLine)
            let response = Self.successResponse()
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                self.stop()
                continuation.resume(returning: result)
            })
        }
    }

    private static func successResponse() -> String {
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Senani authorization complete</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: #08080b;
              color: #ece7dc;
              font: 16px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            main {
              width: min(560px, calc(100vw - 48px));
              padding: 36px;
              border: 1px solid rgba(212, 175, 55, 0.28);
              border-radius: 18px;
              background: rgba(255, 255, 255, 0.045);
              box-shadow: 0 22px 70px rgba(0, 0, 0, 0.45);
            }
            h1 {
              margin: 0 0 12px;
              font: 600 34px Georgia, serif;
              letter-spacing: 0;
            }
            p {
              margin: 0;
              color: #9b948a;
              line-height: 1.55;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Senani authorization complete</h1>
            <p>You can close this tab and open the Senani app.</p>
          </main>
        </body>
        </html>
        """
        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
    }
}
#endif
