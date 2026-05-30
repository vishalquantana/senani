import Foundation

public struct VectorHit: Sendable, Equatable {
    public let id: String
    public let distance: Float
    public let metadata: [String: String]

    public init(id: String, distance: Float, metadata: [String: String]) {
        self.id = id
        self.distance = distance
        self.metadata = metadata
    }
}

public protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float], metadata: [String: String]) throws
    func search(vector: [Float], k: Int) throws -> [VectorHit]
}

public final class InMemoryVectorIndex: VectorIndex, @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let vector: [Float]
        public let metadata: [String: String]
    }

    private var items: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { $0.id < $1.id }
    }

    public func insert(id: String, vector: [Float], metadata: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        items[id] = Entry(id: id, vector: vector, metadata: metadata)
    }

    public func search(vector query: [Float], k: Int) throws -> [VectorHit] {
        lock.lock()
        let snapshot = Array(items.values)
        lock.unlock()

        return snapshot
            .map { item in
                VectorHit(
                    id: item.id,
                    distance: 1 - Self.cosine(query, item.vector),
                    metadata: item.metadata
                )
            }
            .sorted { lhs, rhs in
                (lhs.distance, lhs.id) < (rhs.distance, rhs.id)
            }
            .prefix(max(0, k))
            .map { $0 }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return 0
        }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else {
            return 0
        }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
