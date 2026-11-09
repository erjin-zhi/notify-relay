import Foundation
import Combine

public enum AccessStatus: Equatable, Sendable {
    case unknown
    case ok
    case denied(String)
}

public struct DeliveryLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let appName: String
    public let title: String
    public let result: DeliveryResult
    /// 被转发的那条通知（只存在内存里，不写入磁盘）。
    public let record: NotificationRecord
}

/// 转发引擎：定时检查通知数据库，发现新通知就按规则转发。
@MainActor
public final class RelayEngine: ObservableObject {
    @Published public var config: RelayConfig {
        didSet {
            guard config != oldValue else { return }
            do { try ConfigStore.save(config) } catch { lastError = "保存配置失败：\(error.localizedDescription)" }
        }
    }
    @Published public private(set) var access: AccessStatus = .unknown
    @Published public private(set) var recent: [NotificationRecord] = []
    @Published public private(set) var log: [DeliveryLogEntry] = []
    /// 系统里登记过通知的 App（Bundle ID → 显示名）。
    @Published public private(set) var knownApps: [String: String] = [:]
    /// 每个 App 在系统通知里现有的条数和最近时间，键是小写 Bundle ID。
    @Published public private(set) var appActivity: [String: AppActivity] = [:]
    @Published public private(set) var forwardedCount = 0
    @Published public var lastError: String?
    /// 授权和读取过程的记录，显示在“权限 → 技术细节”里。
    @Published public private(set) var diagnostics: [String] = []

    private let store: NotificationStore
    private var lastRecID: Int64?
    private var timer: Timer?
    private var lastOpenAttempt = Date.distantPast
    private let pollInterval: TimeInterval
    private let session: URLSession

    public init(store: NotificationStore = NotificationStore(), pollInterval: TimeInterval = 1.0, session: URLSession = .shared) {
        self.store = store
        self.pollInterval = pollInterval
        self.session = session
        self.config = ConfigStore.load()
        note(RealHome.isSandboxed ? "运行在沙盒中" : "未使用沙盒")
        note(FolderGrant.restore())
    }

    public func note(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(text)"
        diagnostics.append(line)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
        debugLog(text)
        Self.appendToLogFile(line)
    }

    /// 诊断记录同时写到 `~/Library/Logs/notify-relay/diagnostics.log`（沙盒里在 App 容器内）。
    public static var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/notify-relay/diagnostics.log")
    }

    private static func appendToLogFile(_ line: String) {
        let url = logFileURL
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let data = Data((f.string(from: Date()) + " " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// 用户在选择窗口里选中了文件夹。
    public func grantFolder(_ url: URL) {
        do {
            try FolderGrant.save(url)
            note("已保存文件夹授权：\(url.path)")
        } catch {
            note("\(error)")
            lastError = "\(error)"
            return
        }
        retryAccess()
        if access == .ok { note("通过文件夹授权读到了通知数据库") }
        else if case .denied(let m) = access { note("文件夹已授权，但仍然读不到：\(m)") }
    }

    public var databasePath: String { store.path }

    public func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即重试打开数据库（比如用户刚授权完）。
    public func retryAccess() {
        lastOpenAttempt = .distantPast
        poll()
    }

    private static let debug = ProcessInfo.processInfo.environment["NOTIFY_RELAY_DEBUG"] == "1"
    fileprivate func debugLog(_ message: @autoclosure () -> String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[notify-relay] \(message())\n".utf8))
    }

    func poll() {
        if !store.isOpen {
            // 打不开时每 5 秒重试一次，等用户去授权。
            guard Date().timeIntervalSince(lastOpenAttempt) >= 5 else { return }
            lastOpenAttempt = Date()
            do {
                try store.open()
                if access != .ok { note("已能读取通知数据库\(store.isSnapshotMode ? "（快照方式）" : "")") }
                access = .ok
                refreshKnownApps()
            } catch {
                let message = "\(error)"
                if access != .denied(message) { note("读取通知数据库失败：\(message)") }
                access = .denied(message)
                return
            }
        }
        do {
            if lastRecID == nil {
                // 第一次只记住当前位置，不把历史通知全发一遍。
                lastRecID = try store.maxRecordID()
                debugLog("opened \(store.path), starting after rec_id \(lastRecID!)")
                loadHistory()
                return
            }
            let rows = try store.records(after: lastRecID!)
            guard !rows.isEmpty else { return }
            lastRecID = rows.last!.recID
            debugLog("\(rows.count) new record(s), last rec_id \(lastRecID!)")
            for row in rows { handle(row) }
        } catch {
            debugLog("poll failed: \(error)")
            store.close()
            access = .denied("\(error)")
        }
    }

    /// 启动时把系统里最近的通知放进“最近通知”，只显示，不转发。
    private func loadHistory() {
        guard recent.isEmpty, let rows = try? store.latestRecords(limit: 50) else { return }
        recent = rows.reversed().compactMap { row in
            NotificationRecord.parse(
                recID: row.recID, bundleID: row.bundleID, appName: AppNameResolver.shared.name(for: row.bundleID),
                data: row.data, deliveredDate: row.deliveredDate
            )
        }
    }

    private func handle(_ row: RawRecord) {
        let name = AppNameResolver.shared.name(for: row.bundleID)
        guard let record = NotificationRecord.parse(
            recID: row.recID, bundleID: row.bundleID, appName: name,
            data: row.data, deliveredDate: row.deliveredDate
        ) else { debugLog("cannot parse rec_id \(row.recID)"); return }

        if knownApps[row.bundleID] == nil { knownApps[row.bundleID] = name }
        // 只记录系统是否显示过，不记录通知内容。
        let shown = row.presented.map { $0 ? "已显示" : "未显示" } ?? "未知"
        note("收到 \(name) 的通知（rec_id \(row.recID)）：系统\(shown)，样式 \(row.style.map(String.init) ?? "未知")")
        recent.insert(record, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }

        for webhook in config.targets(for: record.bundleID) {
            deliver(record, to: webhook)
        }
    }

    public func deliver(_ record: NotificationRecord, to webhook: Webhook) {
        let session = self.session
        Task {
            let result = await WebhookSender.send(record, to: webhook, session: session)
            debugLog("\(record.appName) → \(webhook.name): \(result.summary)")
            if result.ok { forwardedCount += 1 }
            log.insert(DeliveryLogEntry(time: Date(), appName: record.appName, title: record.title ?? record.body ?? "", result: result, record: record), at: 0)
            if log.count > 200 { log.removeLast(log.count - 200) }
        }
    }

    /// 某个 WebHook 最近一次测试消息的结果。
    @Published public private(set) var testResults: [UUID: DeliveryResult] = [:]

    public func sendTest(to webhook: Webhook) {
        let session = self.session
        Task {
            let sample = WebhookSender.sampleRecord()
            let result = await WebhookSender.send(sample, to: webhook, session: session)
            testResults[webhook.id] = result
            log.insert(DeliveryLogEntry(time: Date(), appName: "测试消息", title: "测试通知", result: result, record: sample), at: 0)
        }
    }

    public func refreshKnownApps() {
        guard store.isOpen, let ids = try? store.appIdentifiers() else { return }
        var apps: [String: String] = [:]
        for id in ids { apps[id] = AppNameResolver.shared.name(for: id) }
        knownApps = apps
        // 键统一用小写 Bundle ID。
        appActivity = Dictionary(((try? store.appActivity()) ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - 编辑配置的便捷方法

    public func addRule(bundleID: String, appName: String) {
        guard config.rule(for: bundleID) == nil else { return }
        config.appRules.append(AppRule(bundleID: bundleID, appName: appName, webhookIDs: config.defaultRule.webhookIDs))
    }

    public func removeWebhook(_ id: UUID) {
        var c = config
        c.webhooks.removeAll { $0.id == id }
        for i in c.appRules.indices { c.appRules[i].webhookIDs.removeAll { $0 == id } }
        c.defaultRule.webhookIDs.removeAll { $0 == id }
        config = c
    }
}
