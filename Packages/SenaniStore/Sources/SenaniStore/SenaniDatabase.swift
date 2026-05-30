import GRDB

public final class SenaniDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public static func inMemory() throws -> SenaniDatabase {
        let queue = try DatabaseQueue()
        try SenaniMigrations.migrator().migrate(queue)
        return SenaniDatabase(queue: queue)
    }

    public static func file(at path: String) throws -> SenaniDatabase {
        let queue = try DatabaseQueue(path: path)
        try SenaniMigrations.migrator().migrate(queue)
        return SenaniDatabase(queue: queue)
    }
}
