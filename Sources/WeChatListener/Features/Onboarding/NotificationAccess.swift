import CSQLite
import Darwin
import Foundation

/// Effective access to the notification source, not the global state of the TCC permission switch.
enum NotificationAccess: String, Equatable, Sendable {
    case readable
    case denied
    case missing
    case busy
    case unsupported
    case unavailable

    var title: String {
        switch self {
        case .readable: "通知访问已就绪"
        case .denied: "允许读取系统通知"
        case .missing: "尚未找到系统通知"
        case .busy: "系统通知暂时繁忙"
        case .unsupported: "暂不支持当前通知格式"
        case .unavailable: "暂时无法检查通知"
        }
    }

    var detail: String {
        switch self {
        case .readable: "本应用可以读取系统保留的通知。"
        case .denied: "macOS 尚未允许本应用读取系统通知。请检查完全磁盘访问权限；如果已经开启，请在解锁 Mac 后重新打开应用。"
        case .missing: "当前用户的通知存储尚未找到。请先打开微信并接收一条系统通知，然后重试。"
        case .busy: "系统正在使用通知存储。请稍后重新检查，无需重复更改权限。"
        case .unsupported: "通知存储可以访问，但其格式与当前版本不兼容。需要更新应用适配，无需重复更改权限。"
        case .unavailable: "通知存储暂时无法读取，请稍后重新检查。"
        }
    }
}

enum NotificationAccessChecker {
    static func check(_ url: URL) -> NotificationAccess {
        // Probe the actual source from the GUI process; another executable's access proves nothing about this app.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return fileError(errno) }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: 16)
        let count = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { return fileError(errno) }
        guard count == 16, header == Array("SQLite format 3\0".utf8) else { return .unsupported }

        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK else { return databaseError(opened, database: database) }
        sqlite3_busy_timeout(database, 500)
        guard sqlite3_db_readonly(database, "main") == 1 else { return .unavailable }
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        // Validate the exact columns capture needs without fetching notification bodies or importing anything.
        let query = """
            SELECT r.rec_id, r.uuid, r.delivered_date, r.data, a.identifier
            FROM record r JOIN app a ON a.app_id = r.app_id LIMIT 0
            """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepared == SQLITE_OK else { return databaseError(prepared, database: database) }
        let stepped = sqlite3_step(statement)
        return stepped == SQLITE_DONE ? .readable : databaseError(stepped, database: database)
    }

    private static func fileError(_ code: Int32) -> NotificationAccess {
        switch code {
        case EACCES, EPERM: .denied
        case ENOENT, ENOTDIR: .missing
        case EBUSY, EAGAIN: .busy
        default: .unavailable
        }
    }

    private static func databaseError(_ code: Int32, database: OpaquePointer?) -> NotificationAccess {
        switch code & 0xFF {
        case SQLITE_PERM, SQLITE_AUTH: return .denied
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_ERROR, SQLITE_SCHEMA, SQLITE_NOTADB, SQLITE_CORRUPT: return .unsupported
        case SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_READONLY:
            guard let database else { return .unavailable }
            return fileError(sqlite3_system_errno(database))
        default: return .unavailable
        }
    }
}
