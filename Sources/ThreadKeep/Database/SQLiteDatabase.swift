import Foundation
import SQLite3

enum SQLiteDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .prepareFailed(let message), .executionFailed(let message):
            return message
        }
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let databaseURL: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, flags: Int32 = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) throws {
        databaseURL = url

        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteDatabaseError.openFailed("Could not open database at `\(url.path)`: \(message)")
        }

        sqlite3_busy_timeout(handle, 5000) // 5s — retry instead of failing immediately when the db is briefly locked

        if flags & SQLITE_OPEN_READWRITE != 0 || flags & SQLITE_OPEN_CREATE != 0 {
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseError.executionFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteDatabaseError.prepareFailed("Failed to prepare SQL: \(message)\n\(sql)")
        }
        return statement
    }

    func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try block()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Int, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    func bind(_ value: Bool, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindNull(at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_null(statement, index)
    }

    func step(_ statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteDatabaseError.executionFailed(message)
        }
    }

    func finalize(_ statement: OpaquePointer?) {
        sqlite3_finalize(statement)
    }

    func reset(_ statement: OpaquePointer?) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func columnDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    func columnInt(_ statement: OpaquePointer?, index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func columnInt64(_ statement: OpaquePointer?, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func columnData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    func lastInsertedRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }
}
