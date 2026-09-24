import Foundation
import SQLite3

public struct SQLiteError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "本地数据库错误（\(code)）：\(message)" }
}

enum SQLiteValue: Equatable {
    case null, integer(Int), text(String), blob(Data)
    var int: Int? { if case .integer(let value) = self { value } else { nil } }
    var string: String? { if case .text(let value) = self { value } else { nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
}

/// Confined to StudioStore's actor after initialization. No statements escape a call.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let failure = error(code); sqlite3_close_v2(handle); handle = nil; throw failure
        }
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            // Paid request identity must reach durable storage before the caller may POST.
            try execute("PRAGMA synchronous = FULL")
        } catch { sqlite3_close_v2(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close_v2(handle) }
    func close() throws {
        guard let handle else { return }
        let code = sqlite3_close(handle)
        guard code == SQLITE_OK else { throw error(code) }
        self.handle = nil
    }
    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭。")
    }
    @discardableResult
    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        _ = try rows(sql, values)
        return Int(sqlite3_changes(handle))
    }
    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        guard let handle else { throw StudioStoreError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw error(prepared) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw error(SQLITE_MISUSE) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case .text(let text): code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                if data.isEmpty { code = sqlite3_bind_zeroblob(statement, index, 0) }
                else { code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) } }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
        var result: [[SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error(code) }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    return .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: count))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    return .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: count), as: UTF8.self))
                default: return .null
                }
            })
        }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }
}
