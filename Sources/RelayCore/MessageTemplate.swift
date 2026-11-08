import Foundation

/// 消息模板。正文里用 `{{字段名}}` 引用通知字段，例如 `{{title}}`；也可以写中文名 `{{标题}}`。
public struct MessageTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var body: String

    public init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

// MARK: - 内置模板

public enum BuiltinTemplates {
    public static let genericJSON = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000001")!,
        name: "通用 JSON（全部字段）",
        body: """
        {
          "appName": "{{appName}}",
          "bundleID": "{{bundleID}}",
          "title": "{{title}}",
          "subtitle": "{{subtitle}}",
          "body": "{{body}}",
          "date": "{{date}}",
          "notificationID": "{{notificationID}}",
          "threadID": "{{threadID}}",
          "category": "{{category}}",
          "interruptionLevel": "{{interruptionLevel}}",
          "sound": "{{sound}}",
          "badge": "{{badge}}",
          "attachments": "{{attachments}}",
          "userInfo": "{{userInfo}}",
          "sender": "{{sender}}"
        }
        """
    )

    public static let wecomText = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000011")!,
        name: "企业微信 · 文本",
        body: """
        {
          "msgtype": "text",
          "text": {
            "content": "【{{appName}}】{{title}}\\n{{body}}"
          }
        }
        """
    )

    public static let wecomMarkdown = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000012")!,
        name: "企业微信 · Markdown",
        body: """
        {
          "msgtype": "markdown",
          "markdown": {
            "content": "### {{title}}\\n{{body|quote}}\\n<font color=\\"comment\\">{{appName}} · {{date|datetime}}</font>"
          }
        }
        """
    )

    public static let feishuText = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000021")!,
        name: "飞书 · 文本",
        body: """
        {
          "msg_type": "text",
          "content": {
            "text": "【{{appName}}】{{title}}\\n{{body}}"
          }
        }
        """
    )

    public static let dingtalkText = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000031")!,
        name: "钉钉 · 文本",
        body: """
        {
          "msgtype": "text",
          "text": {
            "content": "【{{appName}}】{{title}}\\n{{body}}"
          }
        }
        """
    )

    public static let dingtalkMarkdown = MessageTemplate(
        id: UUID(uuidString: "6E0A0000-0000-4000-8000-000000000032")!,
        name: "钉钉 · Markdown",
        body: """
        {
          "msgtype": "markdown",
          "markdown": {
            "title": "{{appName}}：{{title}}",
            "text": "#### {{appName}}\\n**{{title}}**\\n\\n{{body}}\\n\\n> {{date}}"
          }
        }
        """
    )

    public static let all: [MessageTemplate] = [
        wecomText, wecomMarkdown, feishuText, dingtalkText, dingtalkMarkdown, genericJSON,
    ]

    /// 根据 WebHook 地址猜是哪家平台，返回推荐模板。
    public static func suggested(forURL url: String) -> MessageTemplate? {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return nil }
        if host == "qyapi.weixin.qq.com" { return wecomText }
        if host.hasSuffix("feishu.cn") || host.hasSuffix("larksuite.com") { return feishuText }
        if host == "oapi.dingtalk.com" { return dingtalkText }
        return nil
    }
}

// MARK: - 渲染

public struct RenderedMessage: Sendable {
    public let body: Data
    public let contentType: String
    public let isJSON: Bool
}

public enum TemplateError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)
    case unknownField(String)
    case unknownFilter(String)

    public var description: String {
        switch self {
        case .invalidJSON(let m): return "模板填好字段后不是合法的 JSON：\(m)"
        case .unknownField(let f): return "模板里引用了不存在的字段：{{\(f)}}"
        case .unknownFilter(let f): return "不认识的格式“\(f)”。可用：\(TemplateFilter.allCases.map(\.rawValue).joined(separator: "、"))"
        }
    }
}

/// 字段后面加 `|格式`，例如 `{{date|datetime}}`、`{{body|quote}}`。
public enum TemplateFilter: String, CaseIterable, Sendable {
    /// 时间：00:17
    case time
    /// 日期：2026-11-09
    case date
    /// 月日和时间：11-09 00:17
    case datetime
    /// 每一行前面加“> ”，在 Markdown 里显示成引用块。
    case quote
    /// 换行换成空格，合并成一行。
    case oneline

    public var label: String {
        switch self {
        case .time: return "只显示时间，如 00:17"
        case .date: return "只显示日期，如 2026-11-09"
        case .datetime: return "月日和时间，如 11-09 00:17"
        case .quote: return "每行变成 Markdown 引用"
        case .oneline: return "合并成一行"
        }
    }

    func apply(_ value: String, field: NotificationField, record: NotificationRecord) -> String {
        switch self {
        case .time, .date, .datetime:
            guard field == .date, let d = record.date else { return value }
            let f = DateFormatter()
            f.timeZone = .current
            f.dateFormat = self == .time ? "HH:mm" : (self == .date ? "yyyy-MM-dd" : "MM-dd HH:mm")
            return f.string(from: d)
        case .quote:
            guard !value.isEmpty else { return value }
            return value.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        case .oneline:
            return value.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}

public enum TemplateRenderer {
    /// 匹配 `{{ 字段 }}`。
    public static let placeholderPattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// 占位符里的字段名，去掉 `|格式` 部分。
    public static func field(named name: String) -> NotificationField? {
        let base = name.split(separator: "|", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
        return NotificationField(rawValue: base) ?? NotificationField.allCases.first { $0.label == base }
    }

    /// 占位符里的格式；没有写格式时为 nil，写错时抛错。
    static func filter(in name: String) throws -> TemplateFilter? {
        let parts = name.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let raw = parts[1].trimmingCharacters(in: .whitespaces)
        guard let f = TemplateFilter(rawValue: raw) else { throw TemplateError.unknownFilter(raw) }
        return f
    }

    /// 占位符是否完全有效（字段和格式都认识），用于编辑器高亮。
    public static func isValidPlaceholder(_ name: String) -> Bool {
        guard field(named: name) != nil else { return false }
        do { _ = try filter(in: name); return true } catch { return false }
    }

    /// 模板里引用的字段名（含无法识别的）。
    public static func placeholders(in body: String) -> [(range: NSRange, name: String)] {
        let ns = body as NSString
        return placeholderPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            ($0.range, ns.substring(with: $0.range(at: 1)))
        }
    }

    /// 以 `{` 或 `[` 开头的模板按 JSON 处理：字段值会做 JSON 转义，结果必须是合法 JSON。
    /// 其他模板按纯文本发送。
    public static func isJSONTemplate(_ body: String) -> Bool {
        let trimmed = body.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first else { return false }
        if first == "[" { return true }
        // 以 {{字段}} 开头的是纯文本模板，不是 JSON。
        return first == "{" && !trimmed.hasPrefix("{{")
    }

    public static func render(_ body: String, with record: NotificationRecord) throws -> RenderedMessage {
        let json = isJSONTemplate(body)
        let ns = body as NSString
        var output = ""
        var cursor = 0
        for (range, name) in placeholders(in: body) {
            output += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            guard let field = field(named: name) else { throw TemplateError.unknownField(name) }
            var value = record.value(for: field) ?? ""
            if let f = try filter(in: name) { value = f.apply(value, field: field, record: record) }
            output += json ? jsonEscape(value) : value
            cursor = range.location + range.length
        }
        output += ns.substring(from: cursor)

        let data = Data(output.utf8)
        if json {
            do {
                _ = try JSONSerialization.jsonObject(with: data)
            } catch {
                let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
                throw TemplateError.invalidJSON(reason)
            }
            return RenderedMessage(body: data, contentType: "application/json; charset=utf-8", isJSON: true)
        }
        return RenderedMessage(body: data, contentType: "text/plain; charset=utf-8", isJSON: false)
    }

    /// 转义成可以放进 JSON 字符串里的内容（不带两侧引号）。
    public static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf16.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
