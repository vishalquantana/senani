import Foundation
import SenaniRules

/// The sales pipeline stages a Deal moves through, in canonical left→right order.
/// RawValue strings are the persisted form (the SQLite store and the CRM view both
/// rely on these stable strings); `allCases` defines column order in the view.
public enum DealStage: String, Sendable, CaseIterable, Codable, Equatable {
    case lead, qualified, proposal, negotiation, won, lost

    /// "Open" = not yet closed (neither won nor lost).
    public var isOpen: Bool { self != .won && self != .lost }
}

/// A tracked sales deal. (Authoritative contract owned by the pipeline-crm-view plan.)
public struct Deal: Sendable, Identifiable, Codable, Equatable {
    public var id: String
    public var contactEmail: String
    public var company: String?
    public var stage: DealStage
    public var score: Int?
    public var value: Double?
    public var lastTouch: Date
    public var sourceMessageId: String?
    /// The thread this deal is tracked against. The FollowUp agent looks deals up by
    /// `message.threadId`, which is NOT the same as `message.id` (= `sourceMessageId`), so this
    /// is a first-class stored field rather than an alias of `sourceMessageId`.
    public var threadId: String

    /// `threadId` defaults to `sourceMessageId` (or, failing that, `id`) so existing call sites
    /// that predate the field keep compiling and behaving sensibly; upserting agents pass the real
    /// `message.threadId`.
    public init(id: String, contactEmail: String, company: String? = nil, stage: DealStage,
                score: Int? = nil, value: Double? = nil, lastTouch: Date,
                sourceMessageId: String? = nil, threadId: String? = nil) {
        self.id = id
        self.contactEmail = contactEmail
        self.company = company
        self.stage = stage
        self.score = score
        self.value = value
        self.lastTouch = lastTouch
        self.sourceMessageId = sourceMessageId
        self.threadId = threadId ?? sourceMessageId ?? id
    }
}

/// Read seam over the deals pipeline.
public protocol PipelineReading: Sendable {
    func all() throws -> [Deal]
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func byStage(_ stage: DealStage) throws -> [Deal]
    func deal(threadId: String) throws -> Deal?
}

/// Write seam.
public protocol PipelineTouching: Sendable {
    func upsert(_ deal: Deal) throws
}

/// Unified CRM store seam.
public typealias PipelineStore = PipelineReading & PipelineTouching

/// In-memory PipelineStore for tests, SwiftUI previews, and any agent that needs a real store
/// without a database. Keyed by `Deal.id`; `byContact` matches `contactEmail` case-insensitively.
public final class InMemoryPipelineStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [String: Deal] = [:]

    public init(_ seed: [Deal] = []) {
        for d in seed { deals[d.id] = d }
    }

    public func upsert(_ deal: Deal) throws {
        lock.lock(); defer { lock.unlock() }
        deals[deal.id] = deal
    }
    public func fetch(id: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals[id]
    }
    public func byContact(_ email: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.values.first { $0.contactEmail.caseInsensitiveCompare(email) == .orderedSame }
    }
    public func all() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return Array(deals.values)
    }
    public func byStage(_ stage: DealStage) throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.values.filter { $0.stage == stage }
    }
    public func deal(threadId: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        // Primary key is the real `threadId`; `id` is tolerated as a fallback for deals seeded
        // without thread context.
        return deals.values.first { $0.threadId == threadId || $0.id == threadId }
    }
}

/// No-op default so an `AgentContext` can be constructed without a real pipeline (agents that
/// ignore the CRM, and the existing engine tests). Every read returns empty/nil; `upsert` discards.
public struct NullPipelineStore: PipelineStore {
    public init() {}
    public func upsert(_ deal: Deal) throws {}
    public func fetch(id: String) throws -> Deal? { nil }
    public func byContact(_ email: String) throws -> Deal? { nil }
    public func all() throws -> [Deal] { [] }
    public func byStage(_ stage: DealStage) throws -> [Deal] { [] }
    public func deal(threadId: String) throws -> Deal? { nil }
}

/// Narrow read seam over the message thread store.
public protocol ThreadReading: Sendable {
    func thread(id: String) throws -> [Message]   // date ascending
}
