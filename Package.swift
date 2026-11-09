// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotifyRelay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NotifyRelay", targets: ["NotifyRelay"]),
    ],
    dependencies: [
        // 检查和安装更新。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
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
            dependencies: [
                "RelayCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
