import Foundation
import GRDB

/// Manages the application's SQLite database via GRDB.
///
/// Supports both file-backed (with WAL mode for multi-process access)
/// and in-memory databases (for testing).
public final class AppDatabase: Sendable {
    /// The underlying GRDB database writer (DatabaseQueue or DatabasePool).
    private let dbWriter: any DatabaseWriter

    // MARK: - Factory Methods

    /// Creates a file-backed database at the given path with WAL mode enabled.
    public static func create(path: String) throws -> AppDatabase {
        var config = Configuration()
        config.journalMode = .wal

        let dbPool = try DatabasePool(path: path, configuration: config)
        let appDB = AppDatabase(dbWriter: dbPool)
        try appDB.migrate()
        return appDB
    }

    /// Creates an in-memory database for testing.
    public static func createInMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let appDB = AppDatabase(dbWriter: dbQueue)
        try appDB.migrate()
        return appDB
    }

    /// Legacy convenience — kept for backward compatibility with existing tests.
    public static func inMemory() throws -> AppDatabase {
        try createInMemory()
    }

    /// Legacy path-based init — kept for backward compatibility.
    public init(path: String) throws {
        var config = Configuration()
        config.journalMode = .wal
        self.dbWriter = try DatabasePool(path: path, configuration: config)
        try migrate()
    }

    private init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Access

    /// Provides read access to the database.
    public func reader() -> any DatabaseReader {
        dbWriter
    }

    /// Provides write access to the database.
    public func writer() -> any DatabaseWriter {
        dbWriter
    }

    // MARK: - Migration

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1: Core tables
        migrator.registerMigration("v1") { db in
            // memory table
            try db.create(table: "memory") { t in
                t.primaryKey("id", .text)
                t.column("content", .text).notNull()
                t.column("category", .text).notNull().defaults(to: "general")
                t.column("source", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("metadata", .text)
            }

            // tag table
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }

            // memory_tag join table
            try db.create(table: "memory_tag") { t in
                t.column("memory_id", .text)
                    .notNull()
                    .references("memory", onDelete: .cascade)
                t.column("tag_id", .integer)
                    .notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["memory_id", "tag_id"])
            }
        }

        // v1_fts: Full-text search via FTS5
        migrator.registerMigration("v1_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_fts USING fts5(
                    content,
                    category,
                    source,
                    content='memory',
                    content_rowid='rowid'
                )
                """)

            // Populate FTS with existing data (if any)
            try db.execute(sql: """
                INSERT INTO memory_fts(rowid, content, category, source)
                SELECT rowid, content, category, source FROM memory
                """)

            // Sync triggers
            try db.execute(sql: """
                CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
                    INSERT INTO memory_fts(rowid, content, category, source)
                    VALUES (NEW.rowid, NEW.content, NEW.category, NEW.source);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content, category, source)
                    VALUES('delete', OLD.rowid, OLD.content, OLD.category, OLD.source);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memory_au AFTER UPDATE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content, category, source)
                    VALUES('delete', OLD.rowid, OLD.content, OLD.category, OLD.source);
                    INSERT INTO memory_fts(rowid, content, category, source)
                    VALUES (NEW.rowid, NEW.content, NEW.category, NEW.source);
                END
                """)
        }

        // v2_fts_trigram: Replace unicode61 tokenizer with trigram for CJK support
        migrator.registerMigration("v2_fts_trigram") { db in
            // Drop old FTS table and triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_au")
            try db.execute(sql: "DROP TABLE IF EXISTS memory_fts")

            // Recreate FTS5 with trigram tokenizer (supports Chinese/Japanese/Korean)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_fts USING fts5(
                    content,
                    category,
                    source,
                    content='memory',
                    content_rowid='rowid',
                    tokenize='trigram'
                )
                """)

            // Populate FTS with existing data
            try db.execute(sql: """
                INSERT INTO memory_fts(rowid, content, category, source)
                SELECT rowid, content, category, source FROM memory
                """)

            // Recreate sync triggers
            try db.execute(sql: """
                CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
                    INSERT INTO memory_fts(rowid, content, category, source)
                    VALUES (NEW.rowid, NEW.content, NEW.category, NEW.source);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content, category, source)
                    VALUES('delete', OLD.rowid, OLD.content, OLD.category, OLD.source);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memory_au AFTER UPDATE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content, category, source)
                    VALUES('delete', OLD.rowid, OLD.content, OLD.category, OLD.source);
                    INSERT INTO memory_fts(rowid, content, category, source)
                    VALUES (NEW.rowid, NEW.content, NEW.category, NEW.source);
                END
                """)
        }

        return migrator
    }

    private func migrate() throws {
        try migrator.migrate(dbWriter)
    }
}
