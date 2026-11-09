import AppKit
import SwiftUI
import RelayCore

struct AppEntry: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let url: URL?
}

/// 扫描本机安装的 App。
enum InstalledApps {
    static func scan() async -> [AppEntry] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let roots = [
                "/Applications", "/Applications/Utilities",
                "/System/Applications", "/System/Applications/Utilities",
                RealHome.url.appendingPathComponent("Applications").path,
            ]
            var seen = Set<String>()
            var result: [AppEntry] = []
            func add(_ url: URL) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { return }
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
                    ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                result.append(AppEntry(bundleID: id, name: name, url: url))
            }
            for root in roots {
                guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
                for item in items {
                    if item.pathExtension == "app" { add(item); continue }
                    // 再看一层文件夹，比如 /Applications/Microsoft Office/
                    if let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                        for s in sub where s.pathExtension == "app" { add(s) }
                    }
                }
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }
}

/// “添加 App”面板：发过通知的 App 排在前面，可以搜索、多选。
struct AppPickerSheet: View {
    @EnvironmentObject private var engine: RelayEngine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var installed: [AppEntry] = []
    @State private var loading = true
    @State private var selected = Set<String>()
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 130), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: "给你发过通知的 App",
                        apps: notifiedApps,
                        empty: engine.access == .ok
                            ? (query.isEmpty ? "系统里还没有通知记录" : "没有匹配的 App")
                            : "授权读取通知后，这里会列出给你发过通知的 App，并按通知多少排序。"
                    )
                    section(
                        title: "所有应用",
                        apps: otherApps,
                        empty: loading ? "正在查找本机应用…" : "没有匹配的 App"
                    )
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 560)
        .task {
            engine.refreshKnownApps()
            installed = await InstalledApps.scan()
            loading = false
        }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("添加 App").font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或 Bundle ID", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 260)
            .glassCard(cornerRadius: 10)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("从其他位置选择…") { pickFromDisk() }
            Spacer()
            if !selected.isEmpty {
                Text("已选 \(selected.count) 个").foregroundStyle(.secondary)
            }
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("添加") { addSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .prominentGlassButton()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func section(title: String, apps: [AppEntry], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .glassCard(cornerRadius: 12)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(apps) { app in
                        AppTile(
                            app: app,
                            activity: engine.appActivity[app.bundleID.lowercased()],
                            added: engine.config.rule(for: app.bundleID) != nil,
                            selected: selected.contains(app.bundleID)
                        ) { toggle(app) }
                    }
                }
            }
        }
    }

    // MARK: 数据

    /// 以小写 Bundle ID 为键；数据库里的 App 优先用本机安装的那份信息（有正确的名称和图标）。
    private var allByID: [String: AppEntry] {
        var dict = Dictionary(installed.map { ($0.bundleID.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for (id, name) in engine.knownApps where dict[id.lowercased()] == nil {
            dict[id.lowercased()] = AppEntry(bundleID: id, name: name, url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id))
        }
        return dict
    }

    private func matches(_ app: AppEntry) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || app.name.lowercased().contains(q) || app.bundleID.lowercased().contains(q)
    }

    private var notifiedApps: [AppEntry] {
        let all = allByID
        return engine.knownApps.keys
            .compactMap { all[$0.lowercased()] }
            .filter { $0.url != nil || engine.appActivity[$0.bundleID.lowercased()]?.count ?? 0 > 0 }
            .filter(matches)
            .sorted {
                let a = engine.appActivity[$0.bundleID.lowercased()]?.count ?? 0, b = engine.appActivity[$1.bundleID.lowercased()]?.count ?? 0
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var otherApps: [AppEntry] {
        let notified = Set(engine.knownApps.keys.map { $0.lowercased() })
        return installed.filter { !notified.contains($0.bundleID.lowercased()) && matches($0) }
    }

    private func toggle(_ app: AppEntry) {
        guard engine.config.rule(for: app.bundleID) == nil else { return }
        if selected.contains(app.bundleID) { selected.remove(app.bundleID) } else { selected.insert(app.bundleID) }
    }

    private func addSelected() {
        let all = allByID
        for id in selected {
            engine.addRule(bundleID: id, appName: all[id.lowercased()]?.name ?? AppNameResolver.shared.name(for: id))
        }
        dismiss()
    }

    private func pickFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            engine.addRule(bundleID: id, appName: AppNameResolver.shared.name(for: id))
        }
        dismiss()
    }
}

private struct AppTile: View {
    let app: AppEntry
    let activity: AppActivity?
    let added: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    icon.frame(width: 52, height: 52)
                    if selected || added {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, added ? Color.secondary : Color.accentColor)
                            .font(.system(size: 18))
                            .offset(x: 6, y: -4)
                    }
                }
                Text(app.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 34, alignment: .top)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : (hovering && !added ? Color.primary.opacity(0.06) : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(added ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(added ? "已经添加过规则" : app.bundleID)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = app.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary).padding(6)
        }
    }

    private var caption: String {
        if added { return "已添加" }
        guard let activity, activity.count > 0 else { return " " }
        if let last = activity.lastDate {
            return "\(activity.count) 条 · \(last.formatted(.relative(presentation: .named)))"
        }
        return "\(activity.count) 条通知"
    }
}
