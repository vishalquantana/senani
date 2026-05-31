import Foundation
import Observation
import SenaniEngine
import SenaniRules

/// Owns the Outreach screen's read/select/draft logic. User-initiated and list-driven: it lists
/// the dormant deals the engine surfaces, lets the user pick which to reach out to, and on "Draft
/// outreach" asks the Orchestrator to draft + QUEUE FOR APPROVAL (never auto-send). Pure of SwiftUI
/// and constructed from closure ports so it is testable with in-memory fakes OR the live
/// AppEnvironment graph.
@MainActor
@Observable
public final class OutreachViewModel {
    /// A selectable row over a dormant OutreachTarget.
    public struct Row: Identifiable, Sendable {
        public let id: String                 // the contact email (one target per contact)
        public let contactEmail: String
        public let company: String?
        public let stage: String?
        public let lastTouch: Date?
        public var isSelected: Bool
    }

    public private(set) var rows: [Row] = []
    public private(set) var lastError: String?
    /// Set after a successful draft run: how many drafts were queued for approval.
    public private(set) var lastQueuedCount: Int?
    public private(set) var isDrafting: Bool = false

    private let dormantPort: @Sendable () -> [OutreachTarget]
    private let runOutreachPort: @Sendable ([OutreachTarget]) async throws -> [ProcessedOutcome]

    /// Keyed by contact email so we can rebuild the [OutreachTarget] for the draft call.
    private var targetsByContact: [String: OutreachTarget] = [:]

    public init(
        dormantTargets: @escaping @Sendable () -> [OutreachTarget],
        runOutreach: @escaping @Sendable ([OutreachTarget]) async throws -> [ProcessedOutcome]
    ) {
        self.dormantPort = dormantTargets
        self.runOutreachPort = runOutreach
    }

    /// Live wiring: reads dormant targets and drafts THROUGH the composition root.
    public convenience init(environment env: AppEnvironment) {
        let dormant = env.dormantTargets
        let orchestrator = env.orchestrator
        self.init(
            dormantTargets: dormant,
            runOutreach: { try await orchestrator.runOutreach(to: $0) })
    }

    /// Reload the dormant targets, preserving any existing selection by contact.
    public func refresh() {
        let previouslySelected = Set(rows.filter(\.isSelected).map(\.id))
        let targets = dormantPort()
        targetsByContact = Dictionary(targets.map { ($0.contactEmail, $0) }, uniquingKeysWith: { a, _ in a })
        rows = targets.map { target in
            Row(id: target.contactEmail,
                contactEmail: target.contactEmail,
                company: target.deal?.company,
                stage: target.deal?.stage.rawValue,
                lastTouch: target.deal?.lastTouch,
                isSelected: previouslySelected.contains(target.contactEmail))
        }
    }

    public func toggle(id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].isSelected.toggle()
    }

    public var selectedCount: Int { rows.lazy.filter(\.isSelected).count }

    /// Draft outreach for the selected targets. Results are QUEUED FOR APPROVAL — they appear in the
    /// Approvals screen and are never sent here. Reports how many drafts were queued.
    public func draftSelected() async {
        lastError = nil
        lastQueuedCount = nil
        let selected = rows.filter(\.isSelected).compactMap { targetsByContact[$0.id] }
        guard !selected.isEmpty else { return }
        isDrafting = true
        defer { isDrafting = false }
        do {
            let outcomes = try await runOutreachPort(selected)
            lastQueuedCount = outcomes.count
            refresh()
        } catch {
            lastError = String(describing: error)
        }
    }
}
