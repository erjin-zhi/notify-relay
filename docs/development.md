# SendWord 开发与发布

[返回使用说明](../README.md)

## 构建环境

最低部署目标为 macOS 15.0。从源码构建需要 Swift 6 工具链，以及包含 macOS 26 或更新 SDK 的 Xcode / Command Line Tools；界面使用了新版 SDK 的 Liquid Glass API，并为旧系统提供外观回退。

本文中的命令均在项目根目录执行。

```bash
swift --version
xcrun --show-sdk-version
./scripts/build-app.sh
open build/SendWord.app
```

生成的应用位于 `build/SendWord.app`。脚本默认使用本地临时签名（ad-hoc），没有执行 Apple 公证。

## 构建与测试

项目使用 Swift Package Manager，唯一的第三方依赖是负责自动更新的 [Sparkle](https://github.com/sparkle-project/Sparkle)，数据库访问使用系统 SQLite。

```bash
# 编译
swift build

# 运行单元测试
swift test

# 构建 release 版本、组装 .app 并签名
./scripts/build-app.sh
```

单元测试覆盖通知解析、规则匹配、模板渲染、平台错误响应解析和 SQLite 测试数据库读取；真实系统授权和 Webhook 投递仍需手动验证。

构建脚本默认生成当前构建架构的应用，没有合并为 Universal Binary。若需要使用已有证书签名：

```bash
SIGN_IDENTITY="Apple Development: YOUR NAME (TEAMID)" ./scripts/build-app.sh
```

### 项目结构

```text
.
├── Package.swift                 # SwiftPM 配置
├── Sources/
│   ├── SendWord/                 # 菜单栏、设置、授权引导和模板编辑器
│   └── RelayCore/                # 通知读取、规则匹配、模板渲染和 HTTP 发送
├── Tests/
│   ├── SendWordTests/            # 登录项等应用逻辑测试
│   └── RelayCoreTests/           # 核心逻辑单元测试
├── Resources/                    # 图标、Info.plist 和沙盒权限声明
└── scripts/
    ├── build-app.sh              # 应用打包与签名
    ├── make-icon.swift           # 图标生成
    └── release.sh                # 发布新版本（打包、签名、生成 appcast.xml）
```

### 发布新版本

App 通过 Sparkle 读取 `https://github.com/erjin-zhi/send-word/releases/latest/download/appcast.xml`，因此每个 GitHub Release 都需要上传 `appcast.xml` 和对应的 zip。`scripts/release.sh` 会完成这些步骤：

1. 把 `Info.plist` 的版本号改成指定版本，构建号自动加一（Sparkle 按构建号判断新旧）。
2. 构建、签名 App，压缩成 `build/release/send-word-<版本>.zip`。
3. 用钥匙串中的 EdDSA 私钥（账户 `notify-relay`）签名 zip，生成 `build/release/appcast.xml`。

更新说明可以提前写在 `build/release/notes-<版本>.md`，会显示在更新窗口里。

```bash
# 只生成文件，检查后再手动发布
./scripts/release.sh 0.2.0

# 生成并直接创建 GitHub Release
./scripts/release.sh 0.2.0 --publish
```

私钥只保存在本机钥匙串中，丢失后已安装的用户将无法验证新版本。请导出备份并妥善保管，不要提交到仓库：

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account notify-relay -x send-word-sparkle-key.txt
```

临时签名的构建会关闭强化运行时的库校验（`disable-library-validation`），否则系统不允许加载同为临时签名的 Sparkle.framework；使用正式证书签名时不会添加这项权限。

### 改名与安装兼容

产品中文名为「捎信」，英文名为 `SendWord`，仓库名为 `send-word`。SwiftPM 可执行目标和应用包分别为 `SendWord`、`SendWord.app`，发布压缩包使用 `send-word-<版本>.zip`。

为延续既有安装的数据与更新身份，以下内部标识保留原值：

- Bundle ID：`com.oie0um.notify-relay`，以及由它派生的 Sparkle 沙盒服务名。
- 配置与日志目录：`Application Support/notify-relay`、`Logs/notify-relay`，包括旧版配置迁移路径。
- Sparkle 签名私钥的钥匙串账户：`notify-relay`；更新公钥保持不变。

这些历史名称用于兼容，不需要随产品改名手动迁移。开发调试环境变量统一使用下面的 `SEND_WORD_` 前缀。

Sparkle 从旧版原地更新时，磁盘上的应用文件名可能继续保留为 `notify-relay.app`；新下载包内的应用名为 `SendWord.app`。

### 调试选项

环境变量需传给实际启动的应用进程；直接运行打包后的可执行文件便于查看终端输出：

```bash
SEND_WORD_DEBUG=1 ./build/SendWord.app/Contents/MacOS/SendWord
```

| 环境变量 | 用途 |
| --- | --- |
| `SEND_WORD_DB` | 指定测试用通知数据库路径 |
| `SEND_WORD_CONFIG` | 指定配置文件路径 |
| `SEND_WORD_DEBUG=1` | 在标准错误输出中记录读取与发送调试信息 |
| `SEND_WORD_SNAPSHOT` | 指定截图 / 性能日志输出目录；完成后自动退出 |
| `SEND_WORD_SNAPSHOT_PAGES` | 指定截图页面，逗号分隔，如 `access,rules` |
| `SEND_WORD_SNAPSHOT_DEMO_WEBHOOK` | 启动时往这个地址发两条示例消息（不改配置），让“转发记录”有内容可截图 |
| `SEND_WORD_SNAPSHOT_DETAIL=1` | 截完页面后再打开第一条转发记录的详情并截图 |
| `SEND_WORD_PERF_PAGES` | 指定需要测量侧边栏切换耗时的页面，逗号分隔 |
| `SEND_WORD_FEED_URL` | 用指定的 appcast 地址代替正式更新源，用于本地测试更新流程 |

截图和性能测量选项需要同时设置 `SEND_WORD_SNAPSHOT`。页面标识为 `rules`、`webhooks`、`templates`、`recent`、`general`、`access`、`updates`。截图模式禁用登录项注册和自动更新。自定义路径仍受当前进程的沙盒权限约束。

## 参与贡献

提交 Pull Request 时，请说明改动目的和验证方式。涉及解析、规则或模板逻辑的改动，请补充相应测试并运行 `swift test`。

## 许可证

当前项目尚未指定开源许可证，仓库中没有 `LICENSE` 文件。
