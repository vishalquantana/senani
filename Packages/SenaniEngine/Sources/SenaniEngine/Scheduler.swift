import Foundation
import SenaniRules
import SenaniStore

public actor Scheduler {
    private let sync: any GmailSyncing
    private let store: MessageStore
    private let orchestrator: Orchestrator
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let isLowPower: @Sendable () -> Bool

    private var loop: Task<Void, Never>?

    private let query = "newer_than:7d"
    private let maxResults = 50

    public init(sync: any GmailSyncing,
                store: MessageStore,
                orchestrator: Orchestrator,
                interval: TimeInterval,
                now: @escaping @Sendable () -> Date,
                isLowPower: @escaping @Sendable () -> Bool = { false }) {
        self.sync = sync
        self.store = store
        self.orchestrator = orchestrator
        self.interval = interval
        self.now = now
        self.isLowPower = isLowPower
    }

    @discardableResult
    public func tick() async throws -> [ProcessedOutcome] {
        let fetched = try await sync.fetchMessages(query: query, maxResults: maxResults)
        if !fetched.isEmpty {
            try store.saveAll(fetched)
        }
        return try await orchestrator.processInbox()
    }

    public func start() async {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runCycleIfAllowed()
                let nanos = await self.intervalNanos()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
    }

    private func intervalNanos() async -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private func runCycleIfAllowed() async {
        if isLowPower() { return }
        _ = try? await tick()
    }
}
