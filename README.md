<p align="center">
  <img src="Resources/AppIcon-source.png" width="112" alt="notify-relay 图标">
</p>

<h1 align="center">notify-relay</h1>

<p align="center">把 Mac 上的通知，转发到你指定的 Webhook。</p>

notify-relay 是使用 Swift 和 SwiftUI 开发的原生 macOS 菜单栏应用。它读取本机系统通知，按来源 App 匹配规则，再通过可自定义的消息模板发送到企业微信、飞书、钉钉或你自己的 HTTP 服务。

通知读取、规则匹配和模板渲染均在本机完成，无需部署中转服务器。

[快速开始](#快速开始) · [转发规则](#转发规则) · [消息模板](#消息模板) · [权限与数据](#权限与数据) · [开发](#开发) · [常见问题](#常见问题)

## 功能

- **按 App 转发**：一个 App 可以配置多个 Webhook；未单独配置的 App 可使用默认规则。
- **独立开关**：支持总开关、App 规则开关和 Webhook 开关。
- **自定义消息模板**：支持 JSON 和纯文本，使用 `{{字段}}` 插入通知内容，也支持中文字段名。
- **内置平台模板**：提供企业微信文本 / Markdown、飞书文本、钉钉文本 / Markdown，以及通用 JSON 模板。
- **模板编辑与复用**：输入 `@` 选择字段，查看示例预览，将模板保存为常用模板。
- **通知与发送记录**：查看最近通知和转发结果，从通知直接添加或定位 App 规则。
- **文件夹授权**：优先通过选择通知文件夹授予访问权限，也提供完全磁盘访问权限引导。
- **菜单栏常驻**：在菜单栏查看状态、暂停转发或打开设置。

## 快速开始

### 1. 构建并启动

项目最低部署目标为 **macOS 15.0**。从源码构建需要 Swift 6 工具链，以及包含 macOS 26 或更新 SDK 的 Xcode / Command Line Tools；界面使用了新版 SDK 的 Liquid Glass API，并为旧系统提供外观回退。

下载源码后，在项目根目录执行：

```bash
swift --version
xcrun --show-sdk-version
./scripts/build-app.sh
open build/notify-relay.app
```

生成的应用位于 `build/notify-relay.app`。脚本默认使用本地临时签名（ad-hoc），没有执行 Apple 公证。构建流程详见[开发](#开发)。

首次启动会打开设置窗口，之后可以通过菜单栏铃铛图标进入设置。

### 2. 授权读取通知

在「设置 → 权限」中点击「授权读取通知…」。选择窗口会定位到通知文件夹，直接点击「授权」即可：

```text
~/Library/Group Containers/group.com.apple.usernoted/db2
```

授权成功后，页面会显示「已连接，正在读取新通知」。应用会保存文件夹授权，并在下次启动时尝试恢复。

如果文件夹授权无法读取通知，可点击「打开系统设置」，按引导将 notify-relay 添加到「隐私与安全性 → 完全磁盘访问权限」并开启开关，然后重新检测或重启应用。

### 3. 添加 Webhook

1. 打开「WebHook」页，添加一个目标，填写名称和 HTTP / HTTPS 地址。
2. 从「套用模板」选择目标平台的模板，或编写自己的模板。
3. 点击「发送测试消息」，确认页面显示成功且接收端收到消息。

测试按钮会向目标地址实际发送一条示例消息，不受转发总开关、App 规则或 Webhook 启用状态控制。

### 4. 配置规则

在「转发规则」页点击「添加 App…」，选择来源 App，并勾选要发送到的 Webhook。也可以在「最近通知」中点击「添加规则」。确认总开关、App 规则和目标 Webhook 均已开启，然后让来源 App 产生一条新通知。

默认规则初始为关闭状态。只有开启「转发未单独配置的 App」并选择目标后，其他 App 的通知才会按默认规则转发。

## 转发规则

规则按 App 的 Bundle ID 匹配，不区分大小写。匹配顺序如下：

| 条件 | 行为 |
| --- | --- |
| 总开关关闭 | 继续读取并显示新通知，不发送 |
| App 已有独立规则，且规则开启 | 仅发送到该规则选中的、已启用的 Webhook |
| App 已有独立规则，但规则关闭 | 不发送，也不会回退到默认规则 |
| App 没有独立规则 | 使用默认规则；默认规则关闭时不发送 |

App 规则和默认规则都支持多个目标；同一条规则内重复选择的目标只发送一次。

应用默认每秒检查一次通知数据库。首次成功连接时记录当前位置，仅转发此后新增的通知；「最近通知」会加载最多 50 条历史通知用于查看，随后随新通知更新，最多保留 100 条。**历史通知不会自动补发，暂停转发期间读取的通知也不会在恢复后补发。**

## 消息模板

### 基本用法

使用 `{{字段名}}` 插入通知内容，例如 `{{title}}` 或 `{{标题}}`。模板编辑器支持输入 `@` 选择字段，也可以使用「插入字段」菜单。预览使用示例通知，不会发送网络请求。

纯文本示例：

```text
【{{appName}}】{{title}}
{{body}}
{{date|datetime}}
```

通用 JSON 示例：

```json
{
  "app": "{{appName}}",
  "bundleID": "{{bundleID}}",
  "title": "{{title}}",
  "body": "{{body}}",
  "receivedAt": "{{date}}"
}
```

企业微信 Markdown 示例：

```json
{
  "msgtype": "markdown",
  "markdown": {
    "content": "### {{title}}\n{{body|quote}}\n<font color=\"comment\">{{appName}} · {{date|datetime}}</font>"
  }
}
```

### 发送格式

- 忽略开头空白后，以 `{` 或 `[` 开头的模板按 JSON 处理；以 `{{字段}}` 开头的模板仍按纯文本处理。
- JSON 模板中的字段会自动转义引号、换行等字符，渲染结果必须是合法 JSON。**请将占位符放在 JSON 字符串的双引号内**，例如 `"body": "{{body}}"`。
- JSON 使用 `application/json; charset=utf-8`，纯文本使用 `text/plain; charset=utf-8`，统一通过 HTTP `POST` 发送。
- 缺失字段替换为空字符串；无法识别的字段、格式或非法 JSON 会使本次发送失败，并显示原因。
- 常用模板在套用时复制到 Webhook。之后修改或删除常用模板，不会同步改变已经套用的内容。

### 可用字段

| 字段名 | 中文名称 | 内容 |
| --- | --- | --- |
| `appName` | App 名称 | 根据 Bundle ID 查找的应用显示名 |
| `bundleID` | App Bundle ID | 来源应用的标识 |
| `title` | 标题 | 通知标题 |
| `subtitle` | 副标题 | 通知副标题 |
| `body` | 正文 | 通知正文 |
| `date` | 通知时间 | ISO 8601 格式的时间 |
| `notificationID` | 通知 ID | 通知标识 |
| `threadID` | 分组 ID | 通知所属的会话或分组 |
| `category` | 类别 | 通知类别标识 |
| `interruptionLevel` | 中断级别 | 被动、普通、时间敏感或紧急 |
| `sound` | 声音 | 通知声音名称 |
| `badge` | 角标数 | 应用角标数字的文本形式 |
| `attachments` | 附件 | 附件元数据的文本描述，不会上传附件文件 |
| `userInfo` | 自定义数据 | 应用附带数据的文本描述 |
| `sender` | 发送人 | 通知中可解析的发送人信息 |

字段是否存在、内容是否完整，取决于来源 App 和系统保存的记录。所有字段都以文本替换，`attachments` 和 `userInfo` 也不会直接嵌入为 JSON 对象。

### 格式化

在字段后加 `|格式`，每个占位符支持一个格式。日期和时间格式使用本机时区。

| 写法 | 效果 |
| --- | --- |
| `{{date\|time}}` | `09:30` |
| `{{date\|date}}` | `2026-11-09` |
| `{{date\|datetime}}` | `11-09 09:30` |
| `{{body\|quote}}` | 每行前添加 `> `，用于 Markdown 引用块 |
| `{{body\|oneline}}` | 移除空行，并用空格连接其余各行 |

## 权限与数据

应用通过 SQLite 只读连接访问系统通知数据库，不修改通知记录。打包后的应用启用 App Sandbox；文件夹授权使用安全作用域书签保存。由于 SQLite 的 WAL / 共享内存访问需求，沙盒声明的用户所选文件权限为读写，但业务逻辑只读取通知。

本机读取到的通知可能包含私人消息、验证码或其他敏感内容。请按需选择来源 App、模板字段和可信的接收地址，优先使用 HTTPS。程序不依赖项目方的云端服务，消息按配置直接发送给接收端。

打包应用的数据默认保存在以下沙盒容器内：

```text
~/Library/Containers/com.oie0um.notify-relay/Data/Library/
├── Application Support/notify-relay/config.json
└── Logs/notify-relay/diagnostics.log
```

- `config.json` 保存规则、Webhook 地址和常用模板，**以明文存储**，没有使用钥匙串。Webhook 地址可能包含密钥，请勿将配置文件提交到仓库。
- `diagnostics.log` 记录授权、读取状态及来源 App 等诊断信息；正常诊断记录不写入通知标题和正文。
- 最近通知和转发结果保存在进程内存中；应用重启后会重新读取系统中的最近通知。
- 首次使用沙盒版本时，如果容器内没有配置，程序会尝试从旧位置 `~/Library/Application Support/notify-relay/config.json` 复制配置。

可以在「权限 → 技术细节」中撤销保存的文件夹授权。若还开启了完全磁盘访问权限，需要在系统设置中另行关闭。

## 已知限制

- 通知读取依赖 macOS 的系统通知数据库结构，系统更新可能影响兼容性。最低部署版本不代表所有系统版本和来源 App 都已完成验证。
- 应用需要保持运行才能转发；目前没有内置登录时自动启动设置。
- 暂不支持飞书、钉钉机器人的签名校验，也没有自定义 HTTP 请求头或认证配置。
- 暂无发送失败自动重试、持久化发送队列、限流或超长消息截断；接收平台的消息长度和频率限制仍然适用。
- 仅转发可解析的通知字段，不读取来源 App 的完整聊天记录，也不上传通知附件。

## 开发

项目使用 Swift Package Manager，没有第三方包依赖，数据库访问使用系统 SQLite。

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
│   ├── NotifyRelay/              # 菜单栏、设置、授权引导和模板编辑器
│   └── RelayCore/                # 通知读取、规则匹配、模板渲染和 HTTP 发送
├── Tests/RelayCoreTests/          # 核心逻辑单元测试
├── Resources/                    # 图标、Info.plist 和沙盒权限声明
└── scripts/
    ├── build-app.sh              # 应用打包与签名
    └── make-icon.swift           # 图标生成
```

### 调试选项

环境变量需传给实际启动的应用进程；直接运行打包后的可执行文件便于查看终端输出：

```bash
NOTIFY_RELAY_DEBUG=1 ./build/notify-relay.app/Contents/MacOS/NotifyRelay
```

| 环境变量 | 用途 |
| --- | --- |
| `NOTIFY_RELAY_DB` | 指定测试用通知数据库路径 |
| `NOTIFY_RELAY_CONFIG` | 指定配置文件路径 |
| `NOTIFY_RELAY_DEBUG=1` | 在标准错误输出中记录读取与发送调试信息 |
| `NOTIFY_RELAY_SNAPSHOT` | 指定截图 / 性能日志输出目录；完成后自动退出 |
| `NOTIFY_RELAY_SNAPSHOT_PAGES` | 指定截图页面，逗号分隔，如 `access,rules` |
| `NOTIFY_RELAY_PERF_PAGES` | 指定需要测量侧边栏切换耗时的页面，逗号分隔 |

截图和性能测量选项需要同时设置 `NOTIFY_RELAY_SNAPSHOT`。页面标识为 `rules`、`webhooks`、`templates`、`recent`、`access`。自定义路径仍受当前进程的沙盒权限约束。

## 常见问题

### 最近通知里有记录，为什么没有转发？

启动时加载的历史通知仅供查看。请产生一条新通知，并检查总开关、App 规则开关、所选目标和 Webhook 开关。已有但关闭的 App 规则不会使用默认规则。

### 测试成功，实际通知却没有发送？

测试消息直接发送到当前 Webhook，不验证通知读取权限或 App 规则。请确认权限页显示已连接，并在「最近通知」检查新通知是否出现，以及对应规则是否选择了目标。

### HTTP 200 为什么仍显示失败？

部分平台通过响应 JSON 表示业务错误。程序会检查 `errcode`、`code` 和 `StatusCode`；值非零时，即使 HTTP 状态为 200，也会显示失败原因。

### 授权后仍然读不到通知？

在「权限 → 技术细节」中查看系统返回信息，点击「重新检测」。如果移动或重新签名了应用后访问失效，可重新授予文件夹访问权限；必要时使用完全磁盘访问权限并重启应用。

## 反馈与贡献

欢迎通过 Issue 报告问题或提出建议。请提供 macOS 版本、构建方式、复现步骤、预期行为和实际结果；权限问题可以附上「权限 → 技术细节」中的诊断记录。提交前请隐去 Webhook 密钥、用户名路径和私人通知内容。

提交 Pull Request 时，请说明改动目的和验证方式。涉及解析、规则或模板逻辑的改动，请补充相应测试并运行 `swift test`。

## 许可证

当前项目尚未指定开源许可证，仓库中没有 `LICENSE` 文件。
