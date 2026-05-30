import Foundation
import GRDB

public final class SqliteVecIndex: VectorIndex, @unchecked Sendable {
    private let database: SenaniDatabase
    private let namespace: String

    public init(database: SenaniDatabase, namespace: String = "default") {
        self.database = database
        self.namespace = namespace
    }

    public static func inMemory(namespace: String = "default") throws -> SqliteVecIndex {
        try SqliteVecIndex(database: SenaniDatabase.inMemory(), namespace: namespace)
    }

    public func insert(id: String, vector: [Float], metadata: [String: String]) throws {
        let vectorData = vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let metadataJSON = try SenaniJSON.encodeString(metadata)
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO vec_items (id, namespace, vector, metadata_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  namespace = excluded.namespace,
                  vector = excluded.vector,
                  metadata_json = excluded.metadata_json
                """,
                arguments: [id, namespace, vectorData, metadataJSON]
            )
        }
    }

    public func search(vector query: [Float], k: Int) throws -> [VectorHit] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, vector, metadata_json FROM vec_items WHERE namespace = ?",
                arguments: [namespace]
            )
            return try rows.map { row in
                let data: Data = row["vector"]
                let storedVector = Self.decodeVector(data)
                let metadataJSON: String? = row["metadata_json"]
                let metadata = try metadataJSON.map {
                    try SenaniJSON.decode([String: String].self, from: $0)
                } ?? [:]
                return VectorHit(
                    id: row["id"],
                    distance: 1 - InMemoryVectorIndex.cosine(query, storedVector),
                    metadata: metadata
                )
            }
            .sorted { lhs, rhs in
                (lhs.distance, lhs.id) < (rhs.distance, rhs.id)
            }
            .prefix(max(0, k))
            .map { $0 }
        }
    }

    private static func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count / MemoryLayout<Float>.stride
            guard count > 0 else {
                return []
            }
            return Array(rawBuffer.bindMemory(to: Float.self).prefix(count))
        }
    }
}
