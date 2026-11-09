import SwiftUI
import Combine
import Sparkle

/// 软件更新：用 Sparkle 定期检查 GitHub Releases 上的 appcast.xml，发现新版本时提示下载安装。
/// 更新源、公钥和检查间隔写在 Info.plist（SUFeedURL、SUPublicEDKey、SUScheduledCheckInterval）。
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// 正在检查或安装时为 false，此时“检查更新”按钮不可用。
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    /// 后台检查发现了新版本，但没有立刻弹窗（用户正在用别的 App），在菜单里提示。
    @Published private(set) var pendingVersion: String?
    /// 直接运行二进制（没有打包成 .app）或截图模式下不启用更新。
    let isAvailable: Bool

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    /// 更新包没有被（Ed）DSA 签名配置禁止自动安装时才允许“自动下载并安装”。
    var allowsAutomaticDownloads: Bool { controller?.updater.allowsAutomaticUpdates ?? false }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    private override init() {
        let env = ProcessInfo.processInfo.environment
        isAvailable = Bundle.main.bundleURL.pathExtension == "app" && env["SEND_WORD_SNAPSHOT"] == nil
        super.init()
        guard isAvailable else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastCheckDate)
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// 调试用：用 SEND_WORD_FEED_URL 换成本地的 appcast，测试完整的更新流程。
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["SEND_WORD_FEED_URL"]
    }
}

// 菜单栏 App 没有 Dock 图标，后台检查到更新时如果直接弹窗，窗口常常落在其他 App 后面。
// 按 Sparkle 的“温和提醒”做法：用户此刻没在用本 App 时，只在菜单栏菜单里提示，点开再显示更新窗口。
extension AppUpdater: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}

// MARK: - 设置页

struct UpdatesView: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: updater.currentVersion)
                LabeledContent("上次检查") {
                    if let date = updater.lastCheckDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text("还没有检查过")
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("立即检查更新") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            Section {
                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }))
                Toggle("自动下载并安装更新", isOn: Binding(
                    get: { updater.automaticallyDownloads },
                    set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks || !updater.allowsAutomaticDownloads)
            } footer: {
                Text("每天检查一次 GitHub 上的新版本。开启自动安装后，更新会在后台下载，并在下次退出 App 时完成安装。")
                    .foregroundStyle(.secondary)
            }

            if !updater.isAvailable {
                Section {
                    Text("直接运行可执行文件时不检查更新。请使用打包好的 SendWord.app。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!updater.isAvailable)
    }
}
