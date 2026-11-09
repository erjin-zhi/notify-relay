import AppKit
import QuartzCore
import ScreenCaptureKit
import RelayCore

/// 开发用：设置环境变量 `SEND_WORD_SNAPSHOT=<目录>` 启动时，自动打开设置窗口，
/// 依次截图“初始 → 收起侧边栏过程 → 展开侧边栏过程”，然后退出。只截本 App 自己的窗口。
@MainActor
enum UISnapshot {
    static var directory: URL? {
        guard let p = ProcessInfo.processInfo.environment["SEND_WORD_SNAPSHOT"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// 开发用：`SEND_WORD_SNAPSHOT_DEMO_WEBHOOK=<本地地址>` 时，往这个地址发几条示例消息，
    /// 让“转发记录”里有内容可截图。不改动配置。
    static func sendDemoDeliveries(_ engine: RelayEngine) {
        guard directory != nil, let url = ProcessInfo.processInfo.environment["SEND_WORD_SNAPSHOT_DEMO_WEBHOOK"] else { return }
        let hook = Webhook(name: "本地测试", url: url, template: BuiltinTemplates.wecomText.body)
        engine.deliver(WebhookSender.sampleRecord(), to: hook)
        engine.deliver(WebhookSender.sampleRecord(), to: Webhook(name: "无效地址", url: "notaurl"))
    }

    static func runIfRequested() {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            NotificationCenter.default.post(name: .showSettings, object: nil)
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("settings") == true || $0.title.contains("设置") }) else {
                log(dir, "找不到设置窗口：\(NSApp.windows.map(\.title))")
                NSApp.terminate(nil); return
            }
            window.makeKeyAndOrderFront(nil)
            if let loops = ProcessInfo.processInfo.environment["SEND_WORD_PERF_LOOP"], let n = Int(loops) {
                // 采样用：在当前页反复收起/展开。
                log(dir, "开始循环 \(ProcessInfo.processInfo.processIdentifier)")
                for _ in 0..<n {
                    toggleSidebar(window)
                    try? await Task.sleep(for: .milliseconds(450))
                }
                NSApp.terminate(nil); return
            }
            if let pages = ProcessInfo.processInfo.environment["SEND_WORD_PERF_PAGES"] {
                // 测量模式：每页收起、展开侧边栏各一次，记录主线程最长卡顿。
                for page in pages.split(separator: ",").map(String.init) {
                    NotificationCenter.default.post(name: .selectSettingsPage, object: page)
                    try? await Task.sleep(for: .seconds(1.2))
                    for phase in ["收起", "展开"] {
                        let gaps = await measure { toggleSidebar(window) }
                        log(dir, "\(page) \(phase)：最长卡顿 \(Int(gaps.max * 1000)) ms，超过 25ms 的次数 \(gaps.over)，侧边栏宽度 \(sidebarWidth(window))")
                    }
                }
                NSApp.terminate(nil); return
            }
            if let pages = ProcessInfo.processInfo.environment["SEND_WORD_SNAPSHOT_PAGES"] {
                // 只给这几页各截一张图。
                for page in pages.split(separator: ",").map(String.init) {
                    NotificationCenter.default.post(name: .selectSettingsPage, object: page)
                    try? await Task.sleep(for: .seconds(1.2))
                    await capture(window, dir, "page-\(page)")
                }
                if ProcessInfo.processInfo.environment["SEND_WORD_SNAPSHOT_DETAIL"] == "1" {
                    NotificationCenter.default.post(name: .showFirstDeliveryDetail, object: nil)
                    try? await Task.sleep(for: .seconds(1.2))
                    if let sheet = window.attachedSheet { await capture(sheet, dir, "delivery-detail"); window.endSheet(sheet) }
                    else { log(dir, "没有弹出详情") }
                }
                NSApp.terminate(nil); return
            }
            if let page = ProcessInfo.processInfo.environment["SEND_WORD_SNAPSHOT_PAGE"] {
                NotificationCenter.default.post(name: .selectSettingsPage, object: page)
                try? await Task.sleep(for: .seconds(1))
            }
            await capture(window, dir, "0-initial")
            for phase in ["1-collapse", "2-expand"] {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                for i in 0..<8 {
                    await capture(window, dir, "\(phase)-\(i)")
                    try? await Task.sleep(for: .milliseconds(45))
                }
                try? await Task.sleep(for: .milliseconds(600))
                await capture(window, dir, "\(phase)-end")
            }
            NSApp.terminate(nil)
        }
    }

    /// 直接让窗口里的分栏控制器切换侧边栏（App 不在前台时，菜单命令送不到窗口）。
    private static func toggleSidebar(_ window: NSWindow) {
        func find(_ vc: NSViewController) -> NSSplitViewController? {
            if let s = vc as? NSSplitViewController { return s }
            for c in vc.children { if let s = find(c) { return s } }
            return nil
        }
        if let root = window.contentViewController, let split = find(root) {
            split.toggleSidebar(nil)
        } else if let split = findSplitView(window.contentView)?.delegate as? NSSplitViewController {
            split.toggleSidebar(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
    }

    private static func findSplitView(_ v: NSView?) -> NSSplitView? {
        guard let v else { return nil }
        if let s = v as? NSSplitView { return s }
        for c in v.subviews { if let s = findSplitView(c) { return s } }
        return nil
    }

    private static func sidebarWidth(_ window: NSWindow) -> String {
        func find(_ v: NSView) -> NSSplitView? {
            if let s = v as? NSSplitView { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        guard let root = window.contentView, let split = find(root), let first = split.arrangedSubviews.first else { return "未找到" }
        return split.isSubviewCollapsed(first) ? "已收起" : "\(Int(first.frame.width))"
    }

    /// 执行 action 后 0.8 秒内，主线程两次心跳之间的最大间隔。
    private static func measure(_ action: () -> Void) async -> (max: Double, over: Int) {
        var last = CACurrentMediaTime()
        var maxGap = 0.0, over = 0
        let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let gap = now - last
            if gap > maxGap { maxGap = gap }
            if gap > 0.025 { over += 1 }
            last = now
        }
        RunLoop.main.add(timer, forMode: .common)
        action()
        try? await Task.sleep(for: .milliseconds(800))
        timer.invalidate()
        try? await Task.sleep(for: .milliseconds(300))
        return (maxGap, over)
    }

    private static func capture(_ window: NSWindow, _ dir: URL, _ name: String) async {
        let url = dir.appendingPathComponent(name + ".png")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw NSError(domain: "snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "窗口不在可截取列表里"])
            }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
            write(NSBitmapImageRep(cgImage: image), to: url)
        } catch {
            // 没有屏幕录制权限时退回到视图自绘（毛玻璃效果可能不准，但布局是对的）。
            log(dir, "\(name): ScreenCaptureKit 失败（\(error.localizedDescription)），改用视图自绘")
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            write(rep, to: url)
        }
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func log(_ dir: URL, _ text: String) {
        let url = dir.appendingPathComponent("log.txt")
        let line = Data((text + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
}

extension Notification.Name {
    static let selectSettingsPage = Notification.Name("send-word.selectSettingsPage")
    /// 开发截图用：打开第一条转发记录的详情。
    static let showFirstDeliveryDetail = Notification.Name("send-word.showFirstDeliveryDetail")
}
