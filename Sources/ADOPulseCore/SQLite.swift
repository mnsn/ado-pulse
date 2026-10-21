import Foundation
import SQLite3

public struct SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// SQLite's result code.
    public var code: Int32

    public var primaryCode: Int32 { code & 0xFF }
    public var description: String { message }
}

/// A short-lived, read-only SQLite connection. It never changes the database's contents. Like any
/// reader next to a WAL writer, it takes brief shared locks and updates SQLite's shared-memory
/// index (`-shm`).
final class SQLiteConnection {
    private let handle: OpaquePointer

    /// `immutable` reads the file without any locks or `-wal`/`-shm` files. Only use it while
    /// nothing can write to the file.
    init(readOnly url: URL, immutable: Bool = false) throws {
        var db: OpaquePointer?
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var filename = url.path
        if immutable {
            flags |= SQLITE_OPEN_URI
            filename = url.standardizedFileURL.absoluteString + "?immutable=1"
        }
        let status = sqlite3_open_v2(filename, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite status \(status)"
            if let db { sqlite3_close(db) }
            throw SQLiteError(message: message, code: status)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func rows<T>(_ sql: String, _ map: (SQLiteRow) -> T) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)), code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)), code: status)
            }
            result.append(map(SQLiteRow(statement: statement)))
        }
        return result
    }
}

struct SQLiteRow {
    let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }

    func int64(_ column: Int32) -> Int64? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_int64(statement, column)
        case SQLITE_TEXT: return text(column).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        default: return nil
        }
    }

    func double(_ column: Int32) -> Double? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_double(statement, column)
        default: return nil
        }
    }

    /// The column's bytes, for BLOB and TEXT values.
    func blob(_ column: Int32) -> Data? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_BLOB, SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        default:
            return nil
        }
    }
}
