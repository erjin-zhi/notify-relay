import Combine
import Foundation
import ServiceManagement

/// 注入系统服务，测试时无需注册当前电脑的登录项。
@MainActor
protocol LaunchAtLoginServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 登录项是否启用以系统状态为准，不另存一个可能与系统脱节的开关。
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin(
        service: SystemLaunchAtLoginService(),
        bundleURL: Bundle.main.bundleURL,
        environment: ProcessInfo.processInfo.environment
    )

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    let isAvailable: Bool

    /// 等待系统批准也表示已请求启用；界面需另外提示尚未获准自动启动。
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing, bundleURL: URL, environment: [String: String]) {
        self.service = service
        isAvailable = bundleURL.pathExtension.lowercased() == "app"
            && environment["NOTIFY_RELAY_SNAPSHOT"] == nil
        status = isAvailable ? service.status : .notFound
    }

    /// 返回应用或打开设置页时调用，以反映用户在系统设置中的修改。
    func refresh() {
        guard isAvailable else { return }
        let currentStatus = service.status
        if currentStatus != status { errorMessage = nil }
        status = currentStatus
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        errorMessage = nil
        refresh()

        do {
            if enabled {
                guard !isEnabled else { return }
                try service.register()
            } else {
                guard status != .notRegistered && status != .notFound else { return }
                try service.unregister()
            }
        } catch {
            errorMessage = "无法\(enabled ? "开启" : "关闭")登录时自动启动：\(error.localizedDescription)"
        }

        // 即使系统调用抛错，也重新读取状态，避免界面停留在乐观切换后的值。
        status = service.status
    }

    func openSystemSettings() {
        guard isAvailable else { return }
        service.openSystemSettings()
    }
}
