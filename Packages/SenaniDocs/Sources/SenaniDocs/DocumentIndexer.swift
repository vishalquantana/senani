import Foundation
import GRDB
import SenaniInference
import SenaniStore

public struct DocumentIndexer: Sendable {
    private let database: SenaniDatabase
    private let embedder: any Embedder
    private let vectorIndex: any VectorIndex
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, embedder: any Embedder, vectorIndex: any VectorIndex, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.database = database
        self.embedder = embedder
        self.vectorIndex = vectorIndex
        self.now = now
    }

    public func index(document: ParsedDocument, fields: ExtractedFields) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO documents (id, message_id, filename, kind, text, parsed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  message_id = excluded.message_id,
                  filename = excluded.filename,
                  kind = excluded.kind,
                  text = excluded.text,
                  parsed_at = excluded.parsed_at
                """,
                arguments: [document.id, document.messageId, document.filename, document.kind, document.text, now()]
            )
            try db.execute(sql: "DELETE FROM document_fields WHERE document_id = ?", arguments: [document.id])
            for (name, value) in fields.fields {
                try db.execute(
                    sql: "INSERT INTO document_fields (document_id, name, value) VALUES (?, ?, ?)",
                    arguments: [document.id, name, value]
                )
            }
        }

        for (index, chunk) in Chunker.chunks(text: document.text).enumerated() {
            let vector = try await embedder.embed(chunk)
            try vectorIndex.insert(id: "\(document.id)#\(index)", vector: vector, metadata: [
                "documentId": document.id,
                "messageId": document.messageId,
                "chunk": chunk,
                "filename": document.filename,
            ])
        }
    }
}
