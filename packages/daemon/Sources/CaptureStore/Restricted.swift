import Foundation
import SQLite3

/// The one write a reader may make: an egress record (ADR 0008). Everything else that would
/// change the store is refused by SQLite itself, below any tool handler, so a bug in a reader
/// can't touch a capture, a key, a grant or a revocation. The egress log's own triggers refuse
/// updates and deletes of it.
private let readerAuthorizer: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32 = { _, action, first, _, _, _ in
    let table = first.map { String(cString: $0) }
    switch action {
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_TRANSACTION, SQLITE_SAVEPOINT, SQLITE_RECURSIVE:
        return SQLITE_OK
    case SQLITE_INSERT where table == "egress_record":
        return SQLITE_OK
    // AUTOINCREMENT's bookkeeping in sqlite_sequence isn't put to the authorizer, so nothing more
    // needs allowing for egress_record's ids.
    default:
        return SQLITE_DENY
    }
}

extension CaptureStore {
    /// From now on this connection may read anything a grant allows and append to the egress log,
    /// and write nothing else. Irreversible for this connection. A reader opens with
    /// `init(readerPath:masterKey:)`, which installs this before any SQL runs.
    public func restrictToReading() {
        lock.withLock { installReaderAuthorizer() }
    }

    func installReaderAuthorizer() {
        _ = sqlite3_set_authorizer(db, readerAuthorizer, nil)
    }
}
