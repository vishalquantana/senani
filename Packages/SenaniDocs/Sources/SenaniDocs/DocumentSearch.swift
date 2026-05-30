import GRDB
import SenaniInference
import SenaniStore

public struct DocumentFieldHit: Sendable, Equatable {
    public let documentId: String
    public let name: String
    public let value: String
}

public struct DocumentInsightHit: Sendable, Equatable {
    public let documentId: String
    public let text: String
    public let distance: Float
}

public struct DocumentSearch: Sendable {
    private let database: SenaniDatabase
    private let embedder: any Embedder
    private let vectorIndex: any VectorIndex

    public init(database: SenaniDatabase, embedder: any Embedder, vectorIndex: any VectorIndex) {
        self.database = database
        self.embedder = embedder
        self.vectorIndex = vectorIndex
    }

    public func fields(named name: String) throws -> [DocumentFieldHit] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT document_id, name, value FROM document_fields WHERE name = ? ORDER BY document_id",
                arguments: [name]
            )
            return rows.map { DocumentFieldHit(documentId: $0["document_id"], name: $0["name"], value: $0["value"]) }
        }
    }

    public func semantic(query: String, k: Int) async throws -> [DocumentInsightHit] {
        let vector = try await embedder.embed(query)
        return try vectorIndex.search(vector: vector, k: k).map {
            DocumentInsightHit(documentId: $0.metadata["documentId"] ?? "", text: $0.metadata["chunk"] ?? "", distance: $0.distance)
        }
    }
}
