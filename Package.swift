// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotifyRelay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NotifyRelay", targets: ["NotifyRelay"]),
    ],
    targets: [
        // 不含界面的核心逻辑：读通知数据库、解析记录、匹配规则、发送 WebHook。
        .target(
            name: "RelayCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 菜单栏 App 和设置窗口。
        .executableTarget(
            name: "NotifyRelay",
            dependencies: ["RelayCore"]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
