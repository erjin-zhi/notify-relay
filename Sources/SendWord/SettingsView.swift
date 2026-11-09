import SwiftUI
import UniformTypeIdentifiers
import RelayCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case rules, webhooks, templates, recent, general, access, updates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rules: return "转发规则"
        case .webhooks: return "WebHook"
        case .templates: return "常用模板"
        case .recent: return "最近通知"
        case .general: return "通用"
        case .access: return "权限"
        case .updates: return "软件更新"
        }
    }

    var icon: String {
        switch self {
        case .rules: return "arrow.triangle.branch"
        case .webhooks: return "link"
        case .templates: return "doc.text"
        case .recent: return "clock"
        case .general: return "gearshape"
        case .access: return "lock.shield"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// 设置窗口里的页面跳转：比如从“最近通知”跳到某个 App 的规则。
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage? = .rules
    /// 需要定位并高亮的规则（小写 Bundle ID）。
    @Published var focusRule: String?

    func showRule(_ bundleID: String) {
        focusRule = bundleID.lowercased()
        page = .rules
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: RelayEngine
    @StateObject private var nav = SettingsNavigation()

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $nav.page) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            Group {
                if ProcessInfo.processInfo.environment["SEND_WORD_PERF_BLANK"] == "1" {
                    // 测量用：右侧放空白，得到侧边栏切换本身的开销。
                    Color.clear
                } else {
                switch nav.page ?? .rules {
                case .rules: RulesView()
                case .webhooks: WebhooksView()
                case .templates: TemplatesView()
                case .recent: RecentView()
                case .general: GeneralSettingsView()
                case .access: AccessView()
                case .updates: UpdatesView()
                }
                }
            }
            .environmentObject(nav)
        }
        .onAppear {
            if case .denied = engine.access { nav.page = .access }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsPage)) { n in
            if let raw = n.object as? String, let p = SettingsPage(rawValue: raw) { nav.page = p }
        }
    }
}

// MARK: - 转发规则

struct RulesView: View {
    @EnvironmentObject private var engine: RelayEngine
    @EnvironmentObject private var nav: SettingsNavigation
    @State private var showingPicker = false
    @State private var highlighted: String?

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                Toggle("转发通知（总开关）", isOn: $engine.config.forwardingEnabled)
            }

            Section {
                Toggle("转发未单独配置的 App", isOn: $engine.config.defaultRule.enabled)
                LabeledContent("转发到") {
                    WebhookPicker(selection: $engine.config.defaultRule.webhookIDs)
                }
                .disabled(!engine.config.defaultRule.enabled)
            } header: {
                Text("默认规则")
            } footer: {
                Text("没有添加规则的 App，按这里的设置处理。").foregroundStyle(.secondary)
            }

            Section {
                if engine.config.appRules.isEmpty {
                    Text("还没有 App 规则。点右上角「添加 App」挑选要转发的 App。")
                        .foregroundStyle(.secondary)
                }
                ForEach(engine.config.appRules) { rule in
                    RuleRow(rule: ruleBinding(rule.id), highlighted: highlighted == rule.bundleID.lowercased())
                        .id(rule.bundleID.lowercased())
                }
            } header: {
                HStack {
                    Text("App 规则")
                    Spacer()
                    Button("添加 App…", systemImage: "plus") { showingPicker = true }
                }
            } footer: {
                Text("已添加的 App 只按自己的规则转发；关闭开关即暂停这个 App 的转发。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { focus(proxy) }
        .onChange(of: nav.focusRule) { _, _ in focus(proxy) }
        }
        .navigationTitle("转发规则")
        .sheet(isPresented: $showingPicker) {
            AppPickerSheet().environmentObject(engine)
        }
    }

    /// 滚动到要定位的规则并闪一下。
    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = nav.focusRule else { return }
        nav.focusRule = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            withAnimation(.easeOut(duration: 0.25)) { highlighted = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut(duration: 0.6)) { if highlighted == id { highlighted = nil } }
            }
        }
    }

    private func ruleBinding(_ id: UUID) -> Binding<AppRule> {
        Binding(
            get: { engine.config.appRules.first { $0.id == id } ?? AppRule(bundleID: "", appName: "") },
            set: { new in
                if let i = engine.config.appRules.firstIndex(where: { $0.id == id }) { engine.config.appRules[i] = new }
            }
        )
    }
}

struct RuleRow: View {
    @EnvironmentObject private var engine: RelayEngine
    @Binding var rule: AppRule
    var highlighted = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            AppIcon(bundleID: rule.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.appName)
                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            WebhookPicker(selection: $rule.webhookIDs)
                .frame(maxWidth: 220)
            Button {
                let id = rule.id
                engine.config.appRules.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这条规则")
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.22 : 0))
        )
    }
}

/// 多选 WebHook。
struct WebhookPicker: View {
    @EnvironmentObject private var engine: RelayEngine
    @Binding var selection: [UUID]

    var body: some View {
        Menu(summary) {
            if engine.config.webhooks.isEmpty {
                Text("还没有 WebHook，请先到“WebHook”页添加")
            }
            ForEach(engine.config.webhooks) { w in
                Toggle(w.enabled ? w.name : "\(w.name)（已停用）", isOn: Binding(
                    get: { selection.contains(w.id) },
                    set: { on in
                        if on { if !selection.contains(w.id) { selection.append(w.id) } }
                        else { selection.removeAll { $0 == w.id } }
                    }
                ))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let names = selection.compactMap { id in engine.config.webhooks.first { $0.id == id }?.name }
        return names.isEmpty ? "未选择 WebHook" : names.joined(separator: "、")
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let icon = AppNameResolver.shared.icon(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed").frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 最近通知

struct RecentView: View {
    @EnvironmentObject private var engine: RelayEngine
    @EnvironmentObject private var nav: SettingsNavigation
    @State private var selectedLog: DeliveryLogEntry.ID?
    @State private var detail: DeliveryLogEntry?

    var body: some View {
        VSplitView {
            Table(engine.recent) {
                TableColumn("时间") { r in TimeCell(date: r.date) }
                    .width(70)
                TableColumn("App") { r in Text(r.appName) }
                    .width(min: 80, ideal: 120)
                TableColumn("标题") { r in Text(r.title ?? "") }
                TableColumn("正文") { r in Text(r.body ?? "").lineLimit(2) }
                TableColumn("规则") { r in
                    if engine.config.rule(for: r.bundleID) == nil {
                        Button("添加规则") {
                            engine.addRule(bundleID: r.bundleID, appName: r.appName)
                            nav.showRule(r.bundleID)
                        }
                        .buttonStyle(.link)
                        .help("为 \(r.appName) 添加转发规则")
                    } else {
                        Button {
                            nav.showRule(r.bundleID)
                        } label: {
                            Label("已配置", systemImage: "chevron.right")
                                .labelStyle(TrailingIconLabelStyle())
                        }
                        .buttonStyle(.link)
                        .help("查看或修改 \(r.appName) 的转发规则")
                    }
                }
                .width(80)
            }
            .overlay {
                if engine.recent.isEmpty {
                    Text(engine.access == .ok ? "还没有通知" : "授权读取通知后，这里会显示最近的通知").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("转发记录").font(.headline)
                    Spacer()
                    Text("双击一条记录查看发送内容").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Table(engine.log, selection: $selectedLog) {
                    TableColumn("时间") { e in TimeCell(date: e.time) }
                        .width(70)
                    TableColumn("App") { e in Text(e.appName) }
                        .width(min: 70, ideal: 100)
                    TableColumn("内容") { e in Text(e.title).lineLimit(1).foregroundStyle(.secondary) }
                    TableColumn("转发到") { e in Text(e.result.webhookName).lineLimit(1) }
                        .width(min: 70, ideal: 100)
                    TableColumn("结果") { e in
                        Text(e.result.summary).lineLimit(1).foregroundStyle(e.result.ok ? .green : .red)
                            .help(e.result.summary)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("") { e in
                        Button { detail = e } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .help("查看发送内容")
                    }
                    .width(24)
                }
                .contextMenu(forSelectionType: DeliveryLogEntry.ID.self) { ids in
                    if let e = entry(ids) { Button("查看发送内容") { detail = e } }
                } primaryAction: { ids in
                    detail = entry(ids)
                }
                .overlay {
                    if engine.log.isEmpty { Text("还没有转发记录").foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 160)
        }
        .sheet(item: $detail) { DeliveryDetailView(entry: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .showFirstDeliveryDetail)) { _ in
            detail = engine.log.first { $0.result.request != nil } ?? engine.log.first
        }
        .navigationTitle("最近通知")
    }

    private func entry(_ ids: Set<DeliveryLogEntry.ID>) -> DeliveryLogEntry? {
        guard let id = ids.first else { return nil }
        return engine.log.first { $0.id == id }
    }
}

/// 时间列：数字等宽并靠右，“9:55:04”和“10:17:39”的冒号能对齐。
struct TimeCell: View {
    let date: Date?

    var body: some View {
        Text(date.map { $0.formatted(date: .omitted, time: .standard) } ?? "")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 文字在前、图标在后的标签，用于“已配置 ›”这类链接。
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.title
            configuration.icon.font(.caption2.weight(.semibold))
        }
    }
}
