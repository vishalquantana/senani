import Observation
import SenaniRules
import SenaniStore

/// Owns the Activity Log's read logic. Pure of SwiftUI; the audit port is async
/// because PersistentAuditLog.records() is a throwing method on an actor.
@MainActor
@Observable
public final class ActivityLogViewModel {
    public private(set) var entries: [ActivityEntry] = []
    public private(set) var lastError: String?

    private let recordsPort: @Sendable () async throws -> [AuditEntry]

    public init(records: @escaping @Sendable () async throws -> [AuditEntry]) {
        self.recordsPort = records
    }

    /// Live wiring: reads THROUGH the injected composition root's audit log.
    public convenience init(environment env: AppEnvironment) {
        let audit = env.audit
        self.init(records: { try await audit.records() })
    }

    public func refresh() async {
        do {
            entries = ActivityMapping.timeline(from: try await recordsPort())
        } catch {
            lastError = String(describing: error)
        }
    }
}
