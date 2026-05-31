import Foundation
import SenaniCalendar

/// Narrow async seam giving an Agent read-only access to the user's busy time, without holding
/// a CalendarClient / HTTPClient / token. The composition root injects a concrete provider.
public protocol AvailabilityProviding: Sendable {
    /// Busy intervals overlapping the window, ascending by start.
    func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval]
}

/// Production adapter: wraps `SenaniCalendar.CalendarClient.freeBusy(range:)`. This is the ONLY
/// SenaniEngine type that imports SenaniCalendar; the Booking agent depends only on the seam.
public struct CalendarAvailabilityProvider: AvailabilityProviding {
    private let client: CalendarClient
    public init(client: CalendarClient) { self.client = client }

    public func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval] {
        try await client.freeBusy(range: range).sorted { $0.start < $1.start }
    }
}
