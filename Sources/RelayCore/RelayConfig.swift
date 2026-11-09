import Foundation

public struct Webhook: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var enabled: Bool
    /// 消息模板正文，用 `{{字段}}` 引用通知字段。
    public var template: String

    public init(id: UUID = UUID(), name: String, url: String, enabled: Bool = true, template: String = BuiltinTemplates.genericJSON.body) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.template = template
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? BuiltinTemplates.genericJSON.body
    }
}

/// 某个 App 的转发规则：这个 App 的通知转发到哪些 WebHook。
public struct AppRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var enabled: Bool
    public var webhookIDs: [UUID]

    public init(id: UUID = UUID(), bundleID: String, appName: String, enabled: Bool = true, webhookIDs: [UUID] = []) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.enabled = enabled
        self.webhookIDs = webhookIDs
    }
}

/// 没有单独配置的 App 走的默认规则。
public struct DefaultRule: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var webhookIDs: [UUID]

    public init(enabled: Bool = false, webhookIDs: [UUID] = []) {
        self.enabled = enabled
        self.webhookIDs = webhookIDs
    }
}

public struct RelayConfig: Codable, Hashable, Sendable {
    /// 总开关：关掉后什么都不转发。
    public var forwardingEnabled: Bool
    public var webhooks: [Webhook]
    public var appRules: [AppRule]
    public var defaultRule: DefaultRule
    /// 用户保存的常用模板（内置模板在 `BuiltinTemplates` 里，不存进配置）。
    public var templates: [MessageTemplate]

    public init(forwardingEnabled: Bool = true, webhooks: [Webhook] = [], appRules: [AppRule] = [], defaultRule: DefaultRule = DefaultRule(), templates: [MessageTemplate] = []) {
        self.forwardingEnabled = forwardingEnabled
        self.webhooks = webhooks
        self.appRules = appRules
        self.defaultRule = defaultRule
        self.templates = templates
    }

    // 以后加字段时，旧配置文件缺的键用默认值，不会读失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .forwardingEnabled) ?? true
        webhooks = try c.decodeIfPresent([Webhook].self, forKey: .webhooks) ?? []
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        defaultRule = try c.decodeIfPresent(DefaultRule.self, forKey: .defaultRule) ?? DefaultRule()
        templates = try c.decodeIfPresent([MessageTemplate].self, forKey: .templates) ?? []
    }

    /// 系统通知数据库里的 Bundle ID 是小写的（如 com.tencent.xinwechat），
    /// App 自己声明的可能有大写（com.tencent.xinWeChat），所以不区分大小写匹配。
    public func rule(for bundleID: String) -> AppRule? {
        appRules.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// 一条通知应该发往哪些 WebHook。
    /// 有 App 规则时只看这条规则（规则关闭就不转发）；没有时走默认规则。
    public func targets(for bundleID: String) -> [Webhook] {
        guard forwardingEnabled else { return [] }
        let ids: [UUID]
        if let rule = rule(for: bundleID) {
            guard rule.enabled else { return [] }
            ids = rule.webhookIDs
        } else {
            guard defaultRule.enabled else { return [] }
            ids = defaultRule.webhookIDs
        }
        var seen = Set<UUID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return webhooks.first { $0.id == id && $0.enabled }
        }
    }
}

/// 为兼容已发布版本，继续使用历史目录名；配置保存在 `~/Library/Application Support/notify-relay/config.json`；
/// 设置环境变量 `SEND_WORD_CONFIG` 可改用其他文件（测试用）。
public enum ConfigStore {
    public static var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment["SEND_WORD_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("notify-relay/config.json")
    }

    /// 沙盒之前的配置位置（真实主目录下）。
    public static var legacyFileURL: URL {
        RealHome.url.appendingPathComponent("Library/Application Support/notify-relay/config.json")
    }

    public static func load() -> RelayConfig {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(RelayConfig.self, from: data)
        else { return RelayConfig() }
        return config
    }

    /// 改成沙盒应用后，配置文件位置变到容器里；第一次启动时把旧配置复制过来。
    static func migrateLegacyIfNeeded() {
        let url = fileURL, legacy = legacyFileURL
        guard url.standardizedFileURL != legacy.standardizedFileURL,
              !FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: legacy)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func save(_ config: RelayConfig) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
