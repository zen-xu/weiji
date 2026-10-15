import CSQLite
import Foundation

enum SQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}
let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLite {
    private(set) var handle: OpaquePointer?
    init(_ path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ListenerError(readOnly ? "无法读取系统通知。请给本应用完全磁盘访问权限，退出后重新打开。" : "无法打开本地档案数据库。")
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        _ = try rows(sql, args)
    }
    func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ListenerError("数据库结构不兼容或查询无法执行（\(sqlite3_errcode(handle))）。")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, sqlTransient)
            case .integer(let integer): code = sqlite3_bind_int64(statement, index, integer)
            case .real(let real): code = sqlite3_bind_double(statement, index, real)
            case .blob(let data):
                code = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqlTransient)
                }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw ListenerError("数据库参数绑定失败。") }
        }
        var result = [[String: SQLValue]]()
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var row = [String: SQLValue]()
            for i in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    if let pointer = sqlite3_column_blob(statement, i) {
                        row[key] = .blob(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, i))))
                    }
                default: row[key] = .null
                }
            }
            result.append(row)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw ListenerError("数据库操作失败（\(code)）。") }
        return result
    }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
    func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ListenerError("备份目标已存在，请使用新文件名。") }
        let target = try SQLite(url.path)
        guard let backup = sqlite3_backup_init(target.handle, "main", handle, "main") else {
            throw ListenerError("无法开始备份。")
        }
        let code = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE && finished == SQLITE_OK else { throw ListenerError("数据库忙，备份未完成，请重试。") }
        // Make the backup self-contained; do not leave a WAL-mode header requiring missing sidecars.
        try target.run("PRAGMA journal_mode=DELETE")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Dictionary where Key == String, Value == SQLValue {
    func string(_ key: String) -> String? {
        if case .text(let value) = self[key] { return value }
        return nil
    }
    func int(_ key: String) -> Int64? {
        if case .integer(let value) = self[key] { return value }
        return nil
    }
    func double(_ key: String) -> Double? {
        if case .real(let value) = self[key] { return value }
        if case .integer(let value) = self[key] { return Double(value) }
        return nil
    }
    func data(_ key: String) -> Data? {
        if case .blob(let value) = self[key] { return value }
        return nil
    }
}
