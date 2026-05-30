import Foundation
import GRDB
import SenaniStore

public struct VoiceProfileStore: Sendable {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.database = database
        self.now = now
    }

    public func save(_ profile: VoiceProfile, id: String = "default") throws {
        let json = String(data: try JSONEncoder().encode(profile), encoding: .utf8)!
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO voice_profile (id, scope, profile_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  scope = excluded.scope,
                  profile_json = excluded.profile_json,
                  updated_at = excluded.updated_at
                """,
                arguments: [id, profile.scope, json, now()]
            )
        }
    }

    public func load(id: String = "default") throws -> VoiceProfile? {
        try database.queue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT profile_json FROM voice_profile WHERE id = ?", arguments: [id]),
                  let data = json.data(using: .utf8)
            else { return nil }
            return try JSONDecoder().decode(VoiceProfile.self, from: data)
        }
    }
}
