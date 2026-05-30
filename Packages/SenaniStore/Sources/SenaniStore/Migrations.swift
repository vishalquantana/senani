import GRDB

enum SenaniMigrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core") { db in
            try db.create(table: "rules") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("enabled", .boolean).notNull()
                table.column("json", .text).notNull()
            }

            try db.create(table: "rule_runs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("rule_id", .text).notNull().indexed()
                table.column("kind", .text).notNull()
                table.column("ran_at", .double).notNull()
                table.column("message_id", .text).notNull()
                table.column("matched", .boolean).notNull()
                table.column("outcomes_json", .text).notNull()
            }

            try db.create(table: "actions_log") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("message_id", .text).notNull().indexed()
                table.column("action_json", .text).notNull()
                table.column("trigger_json", .text).notNull()
                table.column("outcome", .text).notNull()
                table.column("logged_at", .double).notNull()
            }

            try db.create(table: "approvals") { table in
                table.column("id", .text).primaryKey()
                table.column("action_json", .text).notNull()
                table.column("message_json", .text).notNull()
                table.column("trigger_json", .text).notNull()
                table.column("status", .text).notNull()
                table.column("created_at", .double).notNull()
            }
        }

        migrator.registerMigration("v2_dependent_tables") { db in
            try db.create(table: "documents") { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text).indexed()
                table.column("filename", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("text", .text)
                table.column("parsed_at", .double)
            }

            try db.create(table: "document_fields") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("document_id", .text).notNull().indexed()
                table.column("name", .text).notNull()
                table.column("value", .text)
            }

            try db.create(table: "voice_profile") { table in
                table.column("id", .text).primaryKey()
                table.column("scope", .text).notNull()
                table.column("profile_json", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "needs_reply") { table in
                table.column("thread_id", .text).primaryKey()
                table.column("message_id", .text).notNull()
                table.column("flagged_at", .double).notNull()
                table.column("resolved", .boolean).notNull()
            }

            try db.create(table: "chat_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("started_at", .double).notNull()
                table.column("transcript_json", .text).notNull()
                table.column("summary", .text)
            }
        }

        migrator.registerMigration("v3_vectors") { db in
            try db.create(table: "vec_items") { table in
                table.column("id", .text).primaryKey()
                table.column("namespace", .text).notNull().indexed()
                table.column("vector", .blob).notNull()
                table.column("metadata_json", .text)
            }
        }

        migrator.registerMigration("v4_messages") { db in
            try db.create(table: "messages") { table in
                table.column("id", .text).primaryKey()
                table.column("from", .text).notNull()
                table.column("senderDomain", .text).notNull().indexed()
                table.column("subject", .text).notNull()
                table.column("body", .text).notNull()
                table.column("hasAttachment", .integer).notNull()
                table.column("listUnsubscribeHeader", .text)
                table.column("labels", .text).notNull()
                table.column("recipients", .text).notNull()
                table.column("threadId", .text).notNull().indexed()
                table.column("date", .double).notNull()
                table.column("isFromUser", .integer).notNull()
            }
        }

        return migrator
    }
}
