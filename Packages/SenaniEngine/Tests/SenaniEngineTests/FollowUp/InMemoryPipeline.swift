import Foundation
@testable import SenaniEngine
import SenaniRules

/// In-memory pipeline + thread store for tests. Records touch() calls so tests can assert
/// Deal.lastTouch updates without a real PipelineStore or SenaniDatabase.
final class InMemoryPipeline: PipelineReading, PipelineTouching, ThreadReading, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [Deal]
    private var threads: [String: [Message]]
    private(set) var touches: [(dealId: String, at: Date)] = []

    init(deals: [Deal], threads: [String: [Message]]) {
        self.deals = deals
        self.threads = threads
    }

    func openDeals() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.filter { $0.stage.isOpen }
    }

    func fetch(id: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.id == id }
    }

    func byContact(_ email: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.contactEmail == email }
    }

    func byStage(_ stage: DealStage) throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.filter { $0.stage == stage }
    }

    func all() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals
    }

    func upsert(_ deal: Deal) throws {
        lock.lock(); defer { lock.unlock() }
        touches.append((deal.id, deal.lastTouch))
        if let i = deals.firstIndex(where: { $0.id == deal.id }) {
            deals[i] = deal
        } else {
            deals.append(deal)
        }
    }

    func thread(id: String) throws -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return (threads[id] ?? []).sorted { $0.date < $1.date }
    }

    func deal(threadId: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.threadId == threadId }
    }

    /// Current snapshot of a deal (post-touch), for assertions.
    func currentDeal(id: String) -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.id == id }
    }
}
