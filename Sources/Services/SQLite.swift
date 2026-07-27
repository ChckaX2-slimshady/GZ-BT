import Foundation
import SQLite3

/// Minimal wrapper over the **system** SQLite3 library (`import SQLite3`, shipped in
/// the SDK — no package added, honoring DECISIONS #8).
///
/// Deliberately thin: it is the migration boundary. If GRDB is ever ratified (it
/// gets a stronger case at S6, when FTS5 arrives), this file is what gets replaced,
/// and nothing above `ConversationDatabase` changes.
///
/// These types are **not** `Sendable` — the `sqlite3` handle must never cross a
/// concurrency domain. They are confined to `ConversationDatabase`'s actor.

enum SQLiteError: LocalizedError {
    case open(path: String, code: Int32, message: String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)
    case pragmaRefused(String)

    var errorDescription: String? {
        switch self {
        case .open(let path, let code, let message):
            "Could not open database at \(path) (code \(code)): \(message)"
        case .prepare(let sql, let message):
            "Could not prepare SQL: \(message)\n\(sql)"
        case .step(let sql, let message):
            "SQL failed: \(message)\n\(sql)"
        case .pragmaRefused(let name):
            "PRAGMA \(name) did not take effect."
        }
    }
}

/// A bindable value. Keeps call sites free of `sqlite3_bind_*` selection.
enum SQLiteValue: Equatable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    static func int(_ value: Int?) -> SQLiteValue { value.map { .int(Int64($0)) } ?? .null }
    static func double(_ value: Double?) -> SQLiteValue { value.map { .double($0) } ?? .null }
    static func bool(_ value: Bool) -> SQLiteValue { .int(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLiteValue { .double(value.timeIntervalSince1970) }
    static func uuid(_ value: UUID) -> SQLiteValue { .text(value.uuidString) }
}

final class SQLiteConnection {
    /// `sqlite3_bind_text` must copy the bytes: our Swift `String` buffer does not
    /// outlive the call. `-1` is SQLITE_TRANSIENT, which is not imported into Swift.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError.open(path: path, code: code, message: message)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    /// Run one or more statements with no results.
    func execute(_ sql: String) throws {
        var raw: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(handle, sql, nil, nil, &raw) == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(raw)
            throw SQLiteError.step(sql: sql, message: message)
        }
    }

    /// Run a statement that returns no rows.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { statement.finalize() }
        _ = try statement.step()
    }

    /// Run a query, mapping each row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], row: (SQLiteRow) -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { statement.finalize() }
        var results: [T] = []
        while try statement.step() { results.append(row(SQLiteRow(statement: statement))) }
        return results
    }

    /// `BEGIN`/`COMMIT`, rolling back on any thrown error. Used for the single
    /// completion transaction in §4.5 step 4.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            // Best-effort rollback: the original error is the one worth reporting.
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Reads a single-integer PRAGMA (used to *assert* `foreign_keys`, per §8).
    func integerPragma(_ name: String) throws -> Int32 {
        let statement = try prepare("PRAGMA \(name);", [])
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        return sqlite3_column_int(statement.raw, 0)
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> SQLiteStatement {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else {
            throw SQLiteError.prepare(sql: sql, message: lastErrorMessage)
        }
        let statement = SQLiteStatement(raw: raw, sql: sql, connection: self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case .text(let string): sqlite3_bind_text(raw, index, string, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(raw, index, number)
            case .double(let number): sqlite3_bind_double(raw, index, number)
            case .null: sqlite3_bind_null(raw, index)
            }
            guard code == SQLITE_OK else {
                statement.finalize()
                throw SQLiteError.prepare(sql: sql, message: lastErrorMessage)
            }
        }
        return statement
    }
}

final class SQLiteStatement {
    fileprivate let raw: OpaquePointer
    private let sql: String
    private unowned let connection: SQLiteConnection

    fileprivate init(raw: OpaquePointer, sql: String, connection: SQLiteConnection) {
        self.raw = raw
        self.sql = sql
        self.connection = connection
    }

    /// `true` when a row is available, `false` at end of statement.
    func step() throws -> Bool {
        switch sqlite3_step(raw) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw SQLiteError.step(sql: sql, message: connection.lastErrorMessage)
        }
    }

    func finalize() { sqlite3_finalize(raw) }
}

/// Column accessors for the current row.
struct SQLiteRow {
    fileprivate let statement: SQLiteStatement

    private func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement.raw, column) == SQLITE_NULL
    }

    func string(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement.raw, column) else { return "" }
        return String(cString: cString)
    }

    func optionalString(_ column: Int32) -> String? {
        isNull(column) ? nil : string(column)
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement.raw, column)) }

    func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement.raw, column) }

    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

    func bool(_ column: Int32) -> Bool { int(column) != 0 }

    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }

    /// Rows whose UUID text is unparseable are a corrupt-store signal; callers
    /// treat `nil` as "skip this row" rather than fabricating an identity.
    func uuid(_ column: Int32) -> UUID? { UUID(uuidString: string(column)) }
}
