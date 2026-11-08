import Foundation

/// 通知的中断级别（数据库键 `intl`）。
public enum InterruptionLevel: Int, Sendable, CaseIterable {
    case passive = 0
    case active = 1
    case timeSensitive = 2
    case critical = 3

    public var label: String {
        switch self {
        case .passive: return "被动"
        case .active: return "普通"
        case .timeSensitive: return "时间敏感"
        case .critical: return "紧急"
        }
    }
}

/// 可以连到 WebHook 模板参数上的通知字段。`rawValue` 是模板里用的参数名。
public enum NotificationField: String, CaseIterable, Sendable, Identifiable {
    case appName
    case bundleID
    case title
    case subtitle
    case body
    case date
    case notificationID
    case threadID
    case category
    case interruptionLevel
    case sound
    case badge
    case attachments
    case userInfo
    case sender

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appName: return "App 名称"
        case .bundleID: return "App Bundle ID"
        case .title: return "标题"
        case .subtitle: return "副标题"
        case .body: return "正文"
        case .date: return "通知时间"
        case .notificationID: return "通知 ID"
        case .threadID: return "分组 ID"
        case .category: return "类别"
        case .interruptionLevel: return "中断级别"
        case .sound: return "声音"
        case .badge: return "角标数"
        case .attachments: return "附件"
        case .userInfo: return "自定义数据"
        case .sender: return "发送人"
        }
    }
}

/// 从系统通知数据库读出的一条通知。缺少的字段为 nil。
public struct NotificationRecord: Identifiable, Hashable, Sendable {
    public let recID: Int64
    public var id: Int64 { recID }

    public var bundleID: String
    public var appName: String
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var date: Date?
    public var notificationID: String?
    public var threadID: String?
    public var category: String?
    public var interruptionLevel: InterruptionLevel?
    public var sound: String?
    public var badge: Int?
    public var attachments: String?
    public var userInfo: String?
    public var sender: String?

    public init(
        recID: Int64, bundleID: String, appName: String,
        title: String? = nil, subtitle: String? = nil, body: String? = nil, date: Date? = nil,
        notificationID: String? = nil, threadID: String? = nil, category: String? = nil,
        interruptionLevel: InterruptionLevel? = nil, sound: String? = nil, badge: Int? = nil,
        attachments: String? = nil, userInfo: String? = nil, sender: String? = nil
    ) {
        self.recID = recID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.notificationID = notificationID
        self.threadID = threadID
        self.category = category
        self.interruptionLevel = interruptionLevel
        self.sound = sound
        self.badge = badge
        self.attachments = attachments
        self.userInfo = userInfo
        self.sender = sender
    }

    /// 字段的文本值，用于发送和以后的模板替换。
    public func value(for field: NotificationField) -> String? {
        switch field {
        case .appName: return appName
        case .bundleID: return bundleID
        case .title: return title
        case .subtitle: return subtitle
        case .body: return body
        case .date: return date.map { Self.dateFormatter.string(from: $0) }
        case .notificationID: return notificationID
        case .threadID: return threadID
        case .category: return category
        case .interruptionLevel: return interruptionLevel?.label
        case .sound: return sound
        case .badge: return badge.map(String.init)
        case .attachments: return attachments
        case .userInfo: return userInfo
        case .sender: return sender
        }
    }

    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - 解析数据库里的二进制 plist

extension NotificationRecord {
    /// 解析 `record.data`。`date` 用的是 Mac 绝对时间（2001-01-01 起的秒数）。
    public static func parse(
        recID: Int64, bundleID: String, appName: String,
        data: Data, deliveredDate: Double?
    ) -> NotificationRecord? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        let req = plist["req"] as? [String: Any] ?? [:]

        var record = NotificationRecord(recID: recID, bundleID: bundleID, appName: appName)
        record.title = nonEmpty(req["titl"] as? String)
        record.subtitle = nonEmpty(req["subt"] as? String)
        record.body = nonEmpty(req["body"] as? String)
        if let t = (plist["date"] as? Double) ?? deliveredDate {
            record.date = Date(timeIntervalSinceReferenceDate: t)
        }
        if let raw = plist["uuid"] as? Data, raw.count == 16 {
            record.notificationID = raw.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }.uuidString
        } else {
            record.notificationID = req["iden"] as? String
        }
        record.threadID = nonEmpty(req["thre"] as? String)
        record.category = nonEmpty(req["cate"] as? String)
        if let level = plist["intl"] as? Int {
            record.interruptionLevel = InterruptionLevel(rawValue: level)
        }
        record.sound = nonEmpty((req["soun"] as? [String: Any])?["nam"] as? String)
        record.badge = req["badg"] as? Int
        record.attachments = req["atta"].map(describe)
        if let usda = req["usda"] {
            // userInfo 通常本身又是一份二进制 plist。
            if let bytes = usda as? Data,
               let inner = try? PropertyListSerialization.propertyList(from: bytes, format: nil) {
                record.userInfo = describe(inner)
            } else {
                record.userInfo = describe(usda)
            }
        }
        record.sender = req["peop"].map(describe)
        return record
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// 把任意 plist 值转成 JSON 文本。
    static func describe(_ value: Any) -> String {
        let safe = jsonSafe(value)
        if let s = safe as? String { return s }
        guard JSONSerialization.isValidJSONObject(safe) || safe is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case let data as Data: return data.base64EncodedString()
        case let date as Date: return dateFormatter.string(from: date)
        case let s as String: return s
        case let n as NSNumber: return n
        default: return String(describing: value)
        }
    }
}
