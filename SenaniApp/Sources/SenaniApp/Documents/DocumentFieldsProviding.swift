import Foundation
import SenaniRules

/// Supplies the `[String: String]` document-field bag the Orchestrator injects into
/// `AgentContext.documentFields`. Best-effort and NON-throwing: any failure (no
/// attachment, fetch error, parse error, extraction error) yields `[:]` so the
/// document-driven agents (InvoiceFinance / ProposalTracker) gracefully fall back
/// to their subject/body heuristics.
public protocol DocumentFieldsProviding: Sendable {
    func fields(for message: Message) async -> [String: String]
}

/// A canned provider for previews/tests. Returns the configured bag for every
/// message (default `[:]`).
public struct FakeDocumentFieldsProvider: DocumentFieldsProviding {
    private let canned: [String: String]

    public init(canned: [String: String] = [:]) {
        self.canned = canned
    }

    public func fields(for message: Message) async -> [String: String] {
        canned
    }
}
