import Foundation
import SQLite3

/// 用户真正的主目录。沙盒里 `homeDirectoryForCurrentUser` 返回的是 App 自己的容器目录。
public enum RealHome {
    public static let url: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// 当前进程是否运行在沙盒里。
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case query(String)

    public var description: String {
        switch self {
        case .cannotOpen(let m): return "无法打开通知数据库：\(m)"
        case .query(let m): return "读取通知数据库失败：\(m)"
        }
    }
}

public struct AppActivity: Sendable, Hashable {
    public let count: Int
    public let lastDate: Date?
}

/// 数据库里的一行原始记录。
public struct RawRecord: Sendable {
    public let recID: Int64
    public let bundleID: String
    public let data: Data
    public let deliveredDate: Double?
    /// 系统有没有把这条通知显示出来（数据库 `record.presented`）。
    public var presented: Bool? = nil
    /// 系统显示用的样式（数据库 `record.style`）。
    public var style: Int? = nil
}

/// 只读访问 macOS 系统通知数据库。
public final class NotificationStore {
    /// 默认路径；设置环境变量 `SEND_WORD_DB` 可改用其他数据库（测试用）。
    public static var defaultPath: String {
        if let p = ProcessInfo.processInfo.environment["SEND_WORD_DB"], !p.isEmpty { return p }
        return RealHome.url.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
    }

    public let path: String
    private var db: OpaquePointer?

    public init(path: String = NotificationStore.defaultPath) {
        self.path = path
    }

    deinit { close() }

    public var isOpen: Bool { db != nil }

    /// 为 true 时表示以 immutable 方式打开，每次读取前都要重新打开才能看到新数据。
    public private(set) var isSnapshotMode = false

    public func open() throws {
        close()
        do {
            try openHandle(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
            isSnapshotMode = false
        } catch where !FileManager.default.fileExists(atPath: path + "-shm")
                    || !FileManager.default.fileExists(atPath: path + "-wal") {
            // WAL 模式的库缺少 -wal/-shm 文件时，只读连接无法自己创建它们。
            // 这种情况下 WAL 已经合并回主库，用 immutable 方式读取，且永远不写入原库。
            let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
            try openHandle(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI)
            isSnapshotMode = true
        }
    }

    private func openHandle(_ name: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(name, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw StoreError.cannotOpen(msg)
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
        // sqlite 打开是惰性的，读一次才能确认有没有权限。
        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(handle, "SELECT 1 FROM record LIMIT 1", -1, &stmt, nil) == SQLITE_OK
            && [SQLITE_ROW, SQLITE_DONE].contains(sqlite3_step(stmt))
        let msg = String(cString: sqlite3_errmsg(handle))
        sqlite3_finalize(stmt)
        if !ok {
            close()
            throw StoreError.cannotOpen(msg)
        }
    }

    /// immutable 方式下重新打开，读到最新内容。
    private func refreshSnapshotIfNeeded() throws {
        guard isSnapshotMode else { return }
        try open()
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    public func maxRecordID() throws -> Int64 {
        try refreshSnapshotIfNeeded()
        var result: Int64 = 0
        try query("SELECT IFNULL(MAX(rec_id), 0) FROM record") { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    /// 最近的若干条记录，按 `rec_id` 升序。
    public func latestRecords(limit: Int) throws -> [RawRecord] {
        let maxID = try maxRecordID()
        var after = max(0, maxID - Int64(limit) * 4)
        var rows = try records(after: after, limit: limit * 4)
        while rows.count < limit && after > 0 {
            after = max(0, after - Int64(limit) * 8)
            rows = try records(after: after, limit: 10_000)
        }
        return Array(rows.suffix(limit))
    }

    /// 返回 `rec_id` 大于给定值的新记录，按 `rec_id` 升序。
    public func records(after recID: Int64, limit: Int = 200) throws -> [RawRecord] {
        try refreshSnapshotIfNeeded()
        var rows: [RawRecord] = []
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date, r.presented, r.style
            FROM record r JOIN app a ON r.app_id = a.app_id
            WHERE r.rec_id > ?1 ORDER BY r.rec_id LIMIT ?2
            """
        try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, recID)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            var data = Data()
            if let blob = sqlite3_column_blob(stmt, 2) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            let delivered: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
            var raw = RawRecord(recID: id, bundleID: bundle, data: data, deliveredDate: delivered)
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL { raw.presented = sqlite3_column_int(stmt, 4) != 0 }
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL { raw.style = Int(sqlite3_column_int(stmt, 5)) }
            rows.append(raw)
        }
        return rows
    }

    /// 每个 App 在数据库里现有的通知条数和最近一条的时间。
    public func appActivity() throws -> [String: AppActivity] {
        try refreshSnapshotIfNeeded()
        var result: [String: AppActivity] = [:]
        let sql = """
            SELECT a.identifier, COUNT(r.rec_id), MAX(r.delivered_date)
            FROM app a LEFT JOIN record r ON r.app_id = a.app_id
            WHERE a.identifier IS NOT NULL GROUP BY a.identifier
            """
        try query(sql) { stmt in
            guard let t = sqlite3_column_text(stmt, 0) else { return }
            let last: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            result[String(cString: t)] = AppActivity(count: Int(sqlite3_column_int64(stmt, 1)), lastDate: last)
        }
        return result
    }

    /// 曾经在系统里登记过通知的全部 App 的 Bundle ID。
    public func appIdentifiers() throws -> [String] {
        try refreshSnapshotIfNeeded()
        var ids: [String] = []
        try query("SELECT identifier FROM app WHERE identifier IS NOT NULL ORDER BY identifier") { stmt in
            if let t = sqlite3_column_text(stmt, 0) { ids.append(String(cString: t)) }
        }
        return ids
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void
    ) throws {
        guard let db else { throw StoreError.query("数据库未打开") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { break }
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
    }
}
