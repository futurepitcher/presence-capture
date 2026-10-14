import Foundation
import SQLite3

/// An SQLite database in memory and nowhere else, what a reader recalls from (ADR 0008): its
/// temporary storage too (temp_store), so a large sort over unsealed content never spills to a file
/// outside the store's directory, where no revocation reaches it.
public final class MemoryIndex {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init() {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { fatalError("can't open an in-memory index") }
        exec("PRAGMA temp_store = MEMORY")
    }

    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("in-memory index: \(String(cString: sqlite3_errmsg(db)))") }
    }

    public func run(_ sql: String, _ values: Any?...) {
        _ = query(sql, values)
    }

    public func ids(_ sql: String, _ values: Any?...) -> [String] {
        query(sql, values).compactMap { $0.first as? String }
    }

    public func rows(_ sql: String, _ values: Any?...) -> [[Any?]] {
        query(sql, values)
    }

    /// Named apart from the variadic ones: an array passed there would bind as a single value.
    private func query(_ sql: String, _ values: [Any?]) -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { fatalError("in-memory index: \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, position)
            // By its length in bytes, not to the first NUL: text can hold one.
            case let text as String: _ = text.withCString { sqlite3_bind_text(statement, position, $0, Int32(text.utf8.count), Self.transient) }
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            default: sqlite3_bind_text(statement, position, "\(value!)", -1, Self.transient)
            }
        }
        var out: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT:
                    let text = sqlite3_column_text(statement, column)!
                    return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                default: return nil
                }
            })
        }
        return out
    }
}
