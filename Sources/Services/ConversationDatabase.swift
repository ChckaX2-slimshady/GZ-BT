import Foundation

/// Owns the SQLite connection and every statement run against it.
///
/// An `actor`, so all SQL executes off the main actor: DB writes must never block
/// token streaming (§8). Only `Sendable` values cross the boundary — the `sqlite3`
/// handle stays inside. Its `@MainActor` façade is `ConversationStore`.
///
/// Layer: **Services**. Nothing in `Inference/` may reference this type (§5).
actor ConversationDatabase {

    /// Bumped per migration. `PRAGMA user_version` makes the runner idempotent (E6).
    static let schemaVersion: Int32 = 1

    private let connection: SQLiteConnection
    nonisolated let path: String

    /// `~/Library/Application Support/GZ-BT/gzbt.sqlite` on macOS — beside `Models/`,
    /// per DECISIONS #18 — and the sandbox equivalent on iOS (§4.6).
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let directory = base.appending(path: "GZ-BT", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "gzbt.sqlite", directoryHint: .notDirectory)
    }

    /// Setup runs on a local connection before it is stored, so no actor-isolated
    /// state is touched from the synchronous initializer.
    init(url: URL) throws {
        let connection = try SQLiteConnection(path: url.path)
        try Self.configure(connection)
        try Self.migrate(connection)
        self.connection = connection
        self.path = url.path
    }

    private static func configure(_ connection: SQLiteConnection) throws {
        // Off by default in raw SQLite3 — E7 (cascade) depends on it, so assert it.
        try connection.execute("PRAGMA foreign_keys = ON;")
        guard try connection.integerPragma("foreign_keys") == 1 else {
            throw SQLiteError.pragmaRefused("foreign_keys")
        }
        // WAL keeps a long read (loading a transcript) from blocking the completion
        // write at the end of a stream.
        try connection.execute("PRAGMA journal_mode = WAL;")
        try connection.execute("PRAGMA synchronous = NORMAL;")
    }

    // MARK: - Migrations

    /// Hand-rolled runner: apply every migration above the stored `user_version`,
    /// then stamp it. Re-running on an already-migrated store is a no-op (E6).
    private static func migrate(_ connection: SQLiteConnection) throws {
        let current = try connection.integerPragma("user_version")
        guard current < schemaVersion else { return }

        if current < 1 {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS conversations (
                  id          TEXT PRIMARY KEY,
                  title       TEXT NOT NULL,
                  created_at  REAL NOT NULL,
                  updated_at  REAL NOT NULL,
                  model_id    TEXT,
                  persona_id  TEXT,
                  archived    INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS messages (
                  id              TEXT PRIMARY KEY,
                  conversation_id TEXT NOT NULL
                                  REFERENCES conversations(id) ON DELETE CASCADE,
                  role            TEXT NOT NULL,
                  content         TEXT NOT NULL,
                  created_at      REAL NOT NULL,
                  sequence        INTEGER NOT NULL,
                  status          TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS message_telemetry (
                  message_id       TEXT PRIMARY KEY
                                   REFERENCES messages(id) ON DELETE CASCADE,
                  model_id         TEXT NOT NULL,
                  engine           TEXT NOT NULL,
                  ttft_ms          REAL,
                  tokens_per_sec   REAL,
                  context_used     INTEGER,
                  context_capacity INTEGER,
                  prompt_tokens    INTEGER,
                  tokens_out       INTEGER,
                  finish_reason    TEXT,
                  schema_version   INTEGER NOT NULL,
                  extra            TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_messages_conv_seq
                  ON messages(conversation_id, sequence);
                CREATE INDEX IF NOT EXISTS idx_conversations_updated
                  ON conversations(updated_at DESC);
                """)
        }

        try connection.execute("PRAGMA user_version = \(schemaVersion);")
    }

    // MARK: - Crash recovery

    /// Any row left `streaming` is a crash artifact — the process died mid-generation
    /// (§4.5 step 6). Returns how many were reclaimed. This is what makes crash
    /// recovery real rather than theoretical.
    @discardableResult
    func sweepInterruptedMessages() throws -> Int {
        let stranded = try connection.query(
            "SELECT COUNT(*) FROM messages WHERE status = 'streaming';") { $0.int(0) }.first ?? 0
        guard stranded > 0 else { return 0 }
        try connection.run(
            "UPDATE messages SET status = 'failed' WHERE status = 'streaming';")
        return stranded
    }

    // MARK: - Conversations

    func conversations(includeArchived: Bool = false) throws -> [Conversation] {
        let sql = """
            SELECT c.id, c.title, c.created_at, c.updated_at, c.model_id, c.persona_id,
                   c.archived, (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id)
            FROM conversations c
            \(includeArchived ? "" : "WHERE c.archived = 0")
            ORDER BY c.updated_at DESC;
            """
        return try connection.query(sql) { row -> Conversation? in
            guard let id = row.uuid(0) else { return nil }
            return Conversation(
                id: id,
                title: row.string(1),
                createdAt: row.date(2),
                updatedAt: row.date(3),
                modelID: row.optionalString(4),
                personaID: row.optionalString(5),
                archived: row.bool(6),
                messageCount: row.int(7))
        }.compactMap { $0 }
    }

    func insert(_ conversation: Conversation) throws {
        try connection.run(
            """
            INSERT INTO conversations (id, title, created_at, updated_at, model_id, persona_id, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [.uuid(conversation.id),
             .text(conversation.title),
             .date(conversation.createdAt),
             .date(conversation.updatedAt),
             .text(conversation.modelID),
             .text(conversation.personaID),
             .bool(conversation.archived)])
    }

    func updateConversation(id: UUID, title: String?, modelID: String?, touchedAt: Date) throws {
        try connection.run(
            """
            UPDATE conversations
               SET title = COALESCE(?, title),
                   model_id = COALESCE(?, model_id),
                   updated_at = ?
             WHERE id = ?;
            """,
            [.text(title), .text(modelID), .date(touchedAt), .uuid(id)])
    }

    /// Cascades to `messages` and `message_telemetry` via the FK clauses (E7).
    func deleteConversation(id: UUID) throws {
        try connection.run("DELETE FROM conversations WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - Messages

    func messages(in conversationID: UUID) throws -> [PersistedMessage] {
        try connection.query(
            """
            SELECT id, conversation_id, role, content, created_at, sequence, status
              FROM messages
             WHERE conversation_id = ?
             ORDER BY sequence ASC;
            """,
            [.uuid(conversationID)]) { row -> PersistedMessage? in
                guard let id = row.uuid(0),
                      let conversationID = row.uuid(1),
                      let role = MessageRole(rawValue: row.string(2)),
                      let status = MessageStatus(rawValue: row.string(6))
                else { return nil }
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: role,
                    content: row.string(3),
                    createdAt: row.date(4),
                    sequence: row.int(5),
                    status: status)
            }.compactMap { $0 }
    }

    /// Next monotonic slot within a conversation. `sequence`, not `created_at`, is the
    /// ordering key — two messages can share a sub-millisecond timestamp.
    func nextSequence(in conversationID: UUID) throws -> Int {
        let highest = try connection.query(
            "SELECT COALESCE(MAX(sequence), -1) FROM messages WHERE conversation_id = ?;",
            [.uuid(conversationID)]) { $0.int(0) }.first ?? -1
        return highest + 1
    }

    func insert(_ message: PersistedMessage) throws {
        try connection.run(
            """
            INSERT INTO messages (id, conversation_id, role, content, created_at, sequence, status)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [.uuid(message.id),
             .uuid(message.conversationID),
             .text(message.role.rawValue),
             .text(message.content),
             .date(message.createdAt),
             .int(message.sequence),
             .text(message.status.rawValue)])
    }

    /// §4.5 step 4/5 — the **single** completion transaction: final content + status,
    /// plus the accumulated telemetry row, committed together or not at all.
    ///
    /// Telemetry is optional because a cancelled or failed turn may never reach
    /// `.completed`; the message row still has to land.
    func finishMessage(
        id: UUID,
        content: String,
        status: MessageStatus,
        telemetry: MessageTelemetry?,
        conversationID: UUID,
        touchedAt: Date
    ) throws {
        try connection.transaction {
            try connection.run(
                "UPDATE messages SET content = ?, status = ? WHERE id = ?;",
                [.text(content), .text(status.rawValue), .uuid(id)])

            if let telemetry {
                try connection.run(
                    """
                    INSERT OR REPLACE INTO message_telemetry
                      (message_id, model_id, engine, ttft_ms, tokens_per_sec,
                       context_used, context_capacity, prompt_tokens, tokens_out,
                       finish_reason, schema_version, extra)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [.uuid(telemetry.messageID),
                     .text(telemetry.modelID),
                     .text(telemetry.engine),
                     .double(telemetry.ttftMs),
                     .double(telemetry.tokensPerSecond),
                     .int(telemetry.contextUsed),
                     .int(telemetry.contextCapacity),
                     .int(telemetry.promptTokens),
                     .int(telemetry.tokensOut),
                     .text(telemetry.finishReason),
                     .int(telemetry.schemaVersion),
                     .text(telemetry.extra)])
            }

            try connection.run(
                "UPDATE conversations SET updated_at = ? WHERE id = ?;",
                [.date(touchedAt), .uuid(conversationID)])
        }
    }

    // MARK: - Telemetry reads (tests + future Spectre)

    func telemetry(for messageID: UUID) throws -> MessageTelemetry? {
        try connection.query(
            """
            SELECT message_id, model_id, engine, ttft_ms, tokens_per_sec, context_used,
                   context_capacity, prompt_tokens, tokens_out, finish_reason,
                   schema_version, extra
              FROM message_telemetry WHERE message_id = ?;
            """,
            [.uuid(messageID)]) { row -> MessageTelemetry? in
                guard let id = row.uuid(0) else { return nil }
                return MessageTelemetry(
                    messageID: id,
                    modelID: row.string(1),
                    engine: row.string(2),
                    ttftMs: row.optionalDouble(3),
                    tokensPerSecond: row.optionalDouble(4),
                    contextUsed: row.optionalInt(5),
                    contextCapacity: row.optionalInt(6),
                    promptTokens: row.optionalInt(7),
                    tokensOut: row.optionalInt(8),
                    finishReason: row.optionalString(9),
                    schemaVersion: row.int(10),
                    extra: row.optionalString(11))
            }.compactMap { $0 }.first
    }

    /// Counts used by the cascade assertion (E7) and the crash-recovery check (E5).
    func counts() throws -> (conversations: Int, messages: Int, telemetry: Int, streaming: Int) {
        func count(_ sql: String) throws -> Int {
            try connection.query(sql) { $0.int(0) }.first ?? 0
        }
        return (
            try count("SELECT COUNT(*) FROM conversations;"),
            try count("SELECT COUNT(*) FROM messages;"),
            try count("SELECT COUNT(*) FROM message_telemetry;"),
            try count("SELECT COUNT(*) FROM messages WHERE status = 'streaming';"))
    }

    /// Rows whose parent no longer exists. Must be 0 with `foreign_keys` on (E7).
    func orphanCounts() throws -> (messages: Int, telemetry: Int) {
        let messages = try connection.query(
            """
            SELECT COUNT(*) FROM messages m
             WHERE NOT EXISTS (SELECT 1 FROM conversations c WHERE c.id = m.conversation_id);
            """) { $0.int(0) }.first ?? 0
        let telemetry = try connection.query(
            """
            SELECT COUNT(*) FROM message_telemetry t
             WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = t.message_id);
            """) { $0.int(0) }.first ?? 0
        return (messages, telemetry)
    }
}
