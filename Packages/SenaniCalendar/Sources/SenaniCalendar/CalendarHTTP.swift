import Foundation
import SenaniGmail

/// HTTP helpers mirroring SenaniGmail's pattern. `GmailAuth.validate(response:data:)` is internal
/// to SenaniGmail, so we re-implement the same check here, reusing the PUBLIC `HTTPClientError`.
public enum CalendarHTTP {
    public static func validate(response: HTTPURLResponse, data: Data) throws {
        guard response.statusCode < 300 else {
            throw HTTPClientError.unexpectedStatus(
                response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }

    /// RFC 3339 in UTC, e.g. "2023-11-14T22:13:20Z" - the format Calendar's timeMin/timeMax expect.
    /// Cached: ISO8601DateFormatter allocation is non-trivial. Configured once then only used for
    /// read-only parse/format, which Foundation documents as thread-safe -> nonisolated(unsafe).
    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Fallback for timestamps carrying fractional seconds, e.g. "...:00.000Z". Google sometimes
    /// emits millisecond precision; without this they'd fail to parse and get compactMap-dropped,
    /// turning real busy windows into phantom free time.
    nonisolated(unsafe) private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func timestamp(_ date: Date) -> String { rfc3339.string(from: date) }

    public static func date(from string: String) -> Date? {
        rfc3339.date(from: string) ?? rfc3339Fractional.date(from: string)
    }
}
