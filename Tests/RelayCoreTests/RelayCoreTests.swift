import XCTest
import SQLite3
@testable import RelayCore

final class RelayCoreTests: XCTestCase {
    /// 按本机数据库实测到的结构构造一条记录。
    static func samplePlist(title: String = "张三", body: String = "晚上一起吃饭？") throws -> Data {
        let userInfo = try PropertyListSerialization.data(fromPropertyList: ["chatID": "abc"], format: .binary, options: 0)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        let plist: [String: Any] = [
            "app": "com.tencent.xinWeChat",
            "uuid": uuidBytes,
            "date": 784_000_000.0,
            "intl": 2,
            "styl": 1,
            "orig": 0,
            "srce": Data([1, 2]),
            "req": [
                "titl": title,
                "subt": "",
                "body": body,
                "cate": "MESSAGE",
                "thre": "chat-1",
                "iden": "req-1",
                "dest": 7,
                "badg": 3,
                "soun": ["nam": "default"],
                "usda": userInfo,
            ] as [String: Any],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func testParseRecord() throws {
        let r = try XCTUnwrap(NotificationRecord.parse(
            recID: 5, bundleID: "com.tencent.xinWeChat", appName: "微信",
            data: Self.samplePlist(), deliveredDate: nil
        ))
        XCTAssertEqual(r.title, "张三")
        XCTAssertNil(r.subtitle, "空字符串按缺失处理")
        XCTAssertEqual(r.body, "晚上一起吃饭？")
        XCTAssertEqual(r.notificationID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(r.threadID, "chat-1")
        XCTAssertEqual(r.category, "MESSAGE")
        XCTAssertEqual(r.interruptionLevel, .timeSensitive)
        XCTAssertEqual(r.sound, "default")
        XCTAssertEqual(r.badge, 3)
        XCTAssertEqual(r.userInfo, #"{"chatID":"abc"}"#)
        XCTAssertEqual(r.date, Date(timeIntervalSinceReferenceDate: 784_000_000))
        XCTAssertEqual(r.value(for: .interruptionLevel), "时间敏感")
    }

    func testRouting() {
        let a = Webhook(name: "A", url: "https://a")
        let b = Webhook(name: "B", url: "https://b")
        let off = Webhook(name: "Off", url: "https://off", enabled: false)
        var c = RelayConfig(
            webhooks: [a, b, off],
            appRules: [
                AppRule(bundleID: "wechat", appName: "微信", webhookIDs: [a.id, b.id, a.id, off.id]),
                AppRule(bundleID: "mail", appName: "邮件", enabled: false, webhookIDs: [a.id]),
            ],
            defaultRule: DefaultRule(enabled: true, webhookIDs: [b.id])
        )
        XCTAssertEqual(c.targets(for: "wechat").map(\.name), ["A", "B"], "多个 WebHook、去重、跳过停用的")
        XCTAssertEqual(c.targets(for: "mail").map(\.name), [], "规则关闭时不走默认规则")
        XCTAssertEqual(c.targets(for: "other").map(\.name), ["B"], "未配置的 App 走默认规则")
        XCTAssertEqual(c.targets(for: "WeChat").map(\.name), ["A", "B"], "Bundle ID 不区分大小写")
        c.defaultRule.enabled = false
        XCTAssertEqual(c.targets(for: "other").map(\.name), [])
        c.forwardingEnabled = false
        XCTAssertEqual(c.targets(for: "wechat").map(\.name), [])
    }

    func testConfigDecodesMissingKeys() throws {
        let c = try JSONDecoder().decode(RelayConfig.self, from: Data(#"{"webhooks":[]}"#.utf8))
        XCTAssertTrue(c.forwardingEnabled)
        XCTAssertFalse(c.defaultRule.enabled)
    }

    func testBuiltinTemplatesRenderValidJSON() throws {
        var r = WebhookSender.sampleRecord()
        r.body = "含 \"引号\"、反斜杠 \\ 和\n换行\t制表"
        for t in BuiltinTemplates.all {
            let msg = try TemplateRenderer.render(t.body, with: r)
            XCTAssertTrue(msg.isJSON, t.name)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: msg.body), t.name)
        }
    }

    func testWeComTextTemplate() throws {
        let msg = try TemplateRenderer.render(BuiltinTemplates.wecomText.body, with: WebhookSender.sampleRecord())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: msg.body) as? [String: Any])
        XCTAssertEqual(obj["msgtype"] as? String, "text")
        let content = (obj["text"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(content, "【notify-relay】测试通知\n这是一条来自 notify-relay 的测试消息")
    }

    func testPlaceholderVariants() throws {
        let r = WebhookSender.sampleRecord()
        // 中文字段名、两侧空格、缺失字段为空
        let msg = try TemplateRenderer.render(#"{"a":"{{ 标题 }}","b":"{{attachments}}"}"#, with: r)
        XCTAssertEqual(String(decoding: msg.body, as: UTF8.self), #"{"a":"测试通知","b":""}"#)
        XCTAssertThrowsError(try TemplateRenderer.render(#"{"a":"{{nope}}"}"#, with: r)) { e in
            XCTAssertEqual(e as? TemplateError, .unknownField("nope"))
        }
        XCTAssertThrowsError(try TemplateRenderer.render(#"{"a": {{title}} }"#, with: r))
        let text = try TemplateRenderer.render("新通知：{{title}}", with: r)
        XCTAssertFalse(text.isJSON)
        XCTAssertEqual(String(decoding: text.body, as: UTF8.self), "新通知：测试通知")
    }

    func testFilters() throws {
        var r = WebhookSender.sampleRecord()
        r.body = "第一行\n第二行"
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 9; c.hour = 0; c.minute = 17
        r.date = Calendar.current.date(from: c)
        let out = try TemplateRenderer.render("{{date|datetime}}|{{date|time}}|{{body|quote}}|{{body|oneline}}", with: r)
        XCTAssertEqual(String(decoding: out.body, as: UTF8.self), "11-09 00:17|00:17|> 第一行\n> 第二行|第一行 第二行")
        XCTAssertThrowsError(try TemplateRenderer.render("{{date|nope}}", with: r)) { e in
            XCTAssertEqual(e as? TemplateError, .unknownFilter("nope"))
        }
        XCTAssertTrue(TemplateRenderer.isValidPlaceholder("body|quote"))
        XCTAssertTrue(TemplateRenderer.isValidPlaceholder("title"), "不写格式也是有效的")
        XCTAssertTrue(TemplateRenderer.isValidPlaceholder("标题"))
        XCTAssertFalse(TemplateRenderer.isValidPlaceholder("nope"))
        XCTAssertFalse(TemplateRenderer.isValidPlaceholder("body|nope"))
    }

    func testWeComMarkdownTemplate() throws {
        var r = WebhookSender.sampleRecord()
        r.body = "A\nB"
        let msg = try TemplateRenderer.render(BuiltinTemplates.wecomMarkdown.body, with: r)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: msg.body) as? [String: Any])
        let content = try XCTUnwrap((obj["markdown"] as? [String: Any])?["content"] as? String)
        XCTAssertTrue(content.hasPrefix("### 测试通知\n> A\n> B\n<font color=\"comment\">notify-relay · "), content)
    }

    func testPlatformErrorDetection() {
        XCTAssertNil(WebhookSender.platformError(in: Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8)))
        XCTAssertNil(WebhookSender.platformError(in: Data(#"{"code":0,"msg":"success"}"#.utf8)))
        XCTAssertNil(WebhookSender.platformError(in: Data("ok".utf8)))
        XCTAssertEqual(WebhookSender.platformError(in: Data(#"{"errcode":93000,"errmsg":"invalid webhook url"}"#.utf8)),
                       "平台返回错误 93000：invalid webhook url")
        XCTAssertNotNil(WebhookSender.platformError(in: Data(#"{"code":19021,"msg":"sign match fail"}"#.utf8)))
    }

    func testSuggestedTemplate() {
        XCTAssertEqual(BuiltinTemplates.suggested(forURL: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x")?.id, BuiltinTemplates.wecomText.id)
        XCTAssertEqual(BuiltinTemplates.suggested(forURL: "https://open.feishu.cn/open-apis/bot/v2/hook/x")?.id, BuiltinTemplates.feishuText.id)
        XCTAssertEqual(BuiltinTemplates.suggested(forURL: "https://oapi.dingtalk.com/robot/send?access_token=x")?.id, BuiltinTemplates.dingtalkText.id)
        XCTAssertNil(BuiltinTemplates.suggested(forURL: "https://example.com"))
    }

    func testOldWebhookConfigGetsDefaultTemplate() throws {
        let json = #"{"webhooks":[{"id":"6E0A0000-0000-4000-8000-0000000000AA","name":"A","url":"https://a","enabled":true}]}"#
        let c = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.webhooks.first?.template, BuiltinTemplates.genericJSON.body)
        XCTAssertEqual(c.templates, [])
    }

    func testStoreReadsFixtureDatabase() throws {
        let path = NSTemporaryDirectory() + "nr-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.makeFixtureDB(at: path, records: [Self.samplePlist(), Self.samplePlist(title: "李四")])

        let store = NotificationStore(path: path)
        try store.open()
        XCTAssertEqual(try store.maxRecordID(), 2)
        let rows = try store.records(after: 1)
        XCTAssertEqual(rows.map(\.recID), [2])
        XCTAssertEqual(rows.first?.bundleID, "com.tencent.xinWeChat")
        let r = NotificationRecord.parse(recID: 2, bundleID: "x", appName: "x", data: rows[0].data, deliveredDate: rows[0].deliveredDate)
        XCTAssertEqual(r?.title, "李四")
        XCTAssertEqual(try store.appIdentifiers(), ["com.tencent.xinWeChat"])
    }

    func testStoreReadsWALDatabaseWithoutShm() throws {
        let path = NSTemporaryDirectory() + "nr-wal-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        try Self.makeFixtureDB(at: path, records: [Self.samplePlist()], wal: true)
        for f in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + f) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))

        let store = NotificationStore(path: path)
        try store.open()
        XCTAssertTrue(store.isSnapshotMode)
        XCTAssertEqual(try store.maxRecordID(), 1)

        // 写入新记录后，下一次读取能看到。
        try Self.makeFixtureDB(at: path, records: [Self.samplePlist(title: "新")], wal: true)
        for f in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + f) }
        XCTAssertEqual(try store.records(after: 1).map(\.recID), [2])
    }

    func testStoreReportsMissingDatabase() {
        let store = NotificationStore(path: "/nonexistent/db")
        XCTAssertThrowsError(try store.open())
        XCTAssertFalse(store.isOpen)
    }

    /// 建一个和系统通知数据库同结构的测试库。
    static func makeFixtureDB(at path: String, records: [Data], wal: Bool = false) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError.cannotOpen(path) }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE IF NOT EXISTS app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
            CREATE TABLE IF NOT EXISTS record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL, presented Bool, style INTEGER, snooze_fire_date REAL);
            INSERT OR IGNORE INTO app (app_id, identifier) VALUES (1, 'com.tencent.xinWeChat');
            """
        if wal { sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) }
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw StoreError.query("schema") }
        for data in records {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO record (app_id, data, delivered_date) VALUES (1, ?1, 784000000)", -1, &stmt, nil)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), nil) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.query("insert") }
            sqlite3_finalize(stmt)
        }
        if wal { sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) }
    }
}
