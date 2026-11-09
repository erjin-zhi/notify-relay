import Foundation

public struct DeliveryResult: Sendable {
    public let webhookID: UUID
    public let webhookName: String
    public let statusCode: Int?
    public let error: String?
    /// 实际发出去的请求，用于在转发记录里查看。模板出错、地址无效时为 nil。
    public var request: SentRequest?
    /// 平台返回的原文（过长时截断）。
    public var responseBody: String?
    /// 从发出请求到收到响应的耗时。
    public var duration: TimeInterval?

    public var ok: Bool { error == nil && (statusCode.map { (200..<300).contains($0) } ?? false) }

    public var summary: String {
        if let error { return "失败：\(error)" }
        if let statusCode { return ok ? "成功（HTTP \(statusCode)）" : "失败（HTTP \(statusCode)）" }
        return "未知结果"
    }
}

/// 发给 WebHook 的请求内容。
public struct SentRequest: Sendable {
    public let url: String
    public let method: String
    public let contentType: String
    public let body: String

    /// 等价的 curl 命令，复制到终端就能重发同样的请求，方便调试。
    public var curlCommand: String {
        """
        curl -X \(method) \(Self.shellQuote(url)) \\
          -H \(Self.shellQuote("Content-Type: \(contentType)")) \\
          --data-raw \(Self.shellQuote(body))
        """
    }

    /// 用单引号包起来；内容里的单引号写成 `'\''`。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 按 WebHook 的模板生成消息并 POST 出去。
public enum WebhookSender {
    public static func send(_ record: NotificationRecord, to webhook: Webhook, session: URLSession = .shared) async -> DeliveryResult {
        var sent: SentRequest?
        func result(_ status: Int?, _ error: String?, response: Data? = nil, duration: TimeInterval? = nil) -> DeliveryResult {
            DeliveryResult(
                webhookID: webhook.id, webhookName: webhook.name, statusCode: status, error: error,
                request: sent, responseBody: response.map(responseText), duration: duration
            )
        }
        guard let url = URL(string: webhook.url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return result(nil, "WebHook 地址无效") }

        let message: RenderedMessage
        do {
            message = try TemplateRenderer.render(webhook.template, with: record)
        } catch {
            return result(nil, "\(error)")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(message.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = message.body
        sent = SentRequest(
            url: url.absoluteString, method: "POST", contentType: message.contentType,
            body: String(decoding: message.body, as: UTF8.self)
        )
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return result(status, platformError(in: data), response: data, duration: Date().timeIntervalSince(start))
        } catch {
            return result(nil, error.localizedDescription, duration: Date().timeIntervalSince(start))
        }
    }

    /// 返回内容转成文字，最多保留 8 KB。
    static func responseText(_ data: Data) -> String {
        let limit = 8 * 1024
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return data.count > limit ? text + "\n…（共 \(data.count) 字节，已截断）" : text
    }

    /// 企业微信、钉钉、飞书出错时 HTTP 状态仍是 200，错误放在返回的 JSON 里。
    /// 企业微信/钉钉：`{"errcode": 93000, "errmsg": "..."}`；飞书：`{"code": 19021, "msg": "..."}`。
    public static func platformError(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for (codeKey, msgKey) in [("errcode", "errmsg"), ("code", "msg"), ("StatusCode", "StatusMessage")] {
            if let code = (obj[codeKey] as? NSNumber)?.intValue, code != 0 {
                let msg = obj[msgKey] as? String ?? ""
                return "平台返回错误 \(code)\(msg.isEmpty ? "" : "：\(msg)")"
            }
        }
        return nil
    }

    /// “测试”按钮和模板预览用的示例通知。
    public static func sampleRecord() -> NotificationRecord {
        NotificationRecord(
            recID: 0, bundleID: "com.oie0um.notify-relay", appName: "notify-relay",
            title: "测试通知", subtitle: "副标题示例", body: "这是一条来自 notify-relay 的测试消息", date: Date(),
            notificationID: UUID().uuidString, threadID: "thread-demo", category: "DEMO",
            interruptionLevel: .active, sound: "default", badge: 1, sender: "张三"
        )
    }
}
