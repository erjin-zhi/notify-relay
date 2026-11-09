import SwiftUI
import RelayCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 打包成 .app 时由 Info.plist 的 LSUIElement 隐藏 Dock 图标；直接运行二进制时在这里设置。
        NSApp.setActivationPolicy(.accessory)
        UISnapshot.runIfRequested()
        // 启动 Sparkle，按 Info.plist 里的间隔在后台检查更新。
        _ = AppUpdater.shared
    }

    /// App 已在运行时再次打开（双击、`open`、Spotlight），弹出设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showSettings, object: nil)
        return false
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("notify-relay.showSettings")
}

/// 菜单栏图标。它一直存在，所以由它负责响应“打开设置”。
struct MenuBarLabel: View {
    let systemImage: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: systemImage)
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

@main
struct NotifyRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine: RelayEngine
    /// 第一次使用（还没有配置文件）或读不到通知时，启动后直接打开设置窗口。
    private let showSettingsAtLaunch: Bool

    init() {
        let isFirstRun = !FileManager.default.fileExists(atPath: ConfigStore.fileURL.path)
        let engine = RelayEngine()
        engine.start()
        _engine = StateObject(wrappedValue: engine)
        showSettingsAtLaunch = isFirstRun || engine.access != .ok
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(engine)
        } label: {
            MenuBarLabel(systemImage: menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("notify-relay 设置", id: "settings") {
            SettingsView()
                .environmentObject(engine)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(showSettingsAtLaunch ? .presented : .suppressed)
    }

    /// 正在转发：带角标的铃铛；暂停：划掉的铃铛；读不到通知：感叹号。
    private var menuIcon: String {
        if case .denied = engine.access { return "exclamationmark.triangle" }
        return engine.config.forwardingEnabled ? "bell.badge" : "bell.slash"
    }
}

struct MenuContent: View {
    @EnvironmentObject private var engine: RelayEngine
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let version = updater.pendingVersion {
            Button("发现新版本 \(version)…") { updater.checkForUpdates() }
            Divider()
        }

        switch engine.access {
        case .ok where engine.config.forwardingEnabled:
            Text("正在转发通知 · 本次已转发 \(engine.forwardedCount) 条")
        case .ok:
            Text("已暂停转发 · 新通知只记录，不发送")
        case .unknown:
            Text("正在连接通知数据库…")
        case .denied:
            Text("还没有授权，暂时无法转发")
        }

        Toggle("转发通知", isOn: $engine.config.forwardingEnabled)

        Divider()

        Button("设置…") { showSettings() }
            .keyboardShortcut(",")
        Button("检查更新…") { updater.checkForUpdates() }
            .disabled(!updater.isAvailable || !updater.canCheckForUpdates)

        Divider()

        Button("退出 notify-relay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
