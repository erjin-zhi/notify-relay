import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        Form {
            Section {
                Toggle("登录 Mac 时自动启动", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .disabled(!launchAtLogin.isAvailable)

                if launchAtLogin.isAvailable {
                    switch launchAtLogin.status {
                    case .enabled:
                        Label("已开启登录时自动启动", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    case .requiresApproval:
                        Label("还需在系统设置中允许 notify-relay 自动启动。", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    case .notFound:
                        Text("系统未找到此应用的登录项。请将应用放入「应用程序」文件夹后重试。")
                            .foregroundStyle(.secondary)
                    case .notRegistered:
                        EmptyView()
                    @unknown default:
                        Text("请在系统设置中查看登录项状态。")
                            .foregroundStyle(.secondary)
                    }

                    Button("打开系统登录项设置…") {
                        launchAtLogin.openSystemSettings()
                    }
                } else {
                    Text("请使用安装后的 notify-relay.app 设置自动启动。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("启动")
            } footer: {
                Text("登录 Mac 后自动在菜单栏运行，沿用上次的转发设置。")
                    .foregroundStyle(.secondary)
            }

            if let error = launchAtLogin.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}
