import SwiftUI
import RelayCore

// MARK: - WebHook 页

struct WebhooksView: View {
    @EnvironmentObject private var engine: RelayEngine
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(engine.config.webhooks) { w in
                    HStack {
                        Circle()
                            .fill(w.enabled ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(w.name.isEmpty ? "未命名" : w.name)
                    }
                    .tag(w.id)
                }
            }
            .overlay {
                if engine.config.webhooks.isEmpty {
                    Text("还没有 WebHook").foregroundStyle(.secondary)
                }
            }
            .frame(width: 190)

            Divider()

            Group {
                if let id = selection, engine.config.webhooks.contains(where: { $0.id == id }) {
                    WebhookEditor(webhook: binding(id), onDelete: { delete(id) })
                        .id(id)
                } else {
                    Text("选择或添加一个 WebHook").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("WebHook")
        .toolbar {
            Button {
                let w = Webhook(name: "WebHook \(engine.config.webhooks.count + 1)", url: "")
                engine.config.webhooks.append(w)
                selection = w.id
            } label: {
                Label("添加 WebHook", systemImage: "plus")
            }
        }
        .onAppear {
            if selection == nil { selection = engine.config.webhooks.first?.id }
        }
    }

    private func delete(_ id: UUID) {
        engine.removeWebhook(id)
        selection = engine.config.webhooks.first?.id
    }

    private func binding(_ id: UUID) -> Binding<Webhook> {
        Binding(
            get: { engine.config.webhooks.first { $0.id == id } ?? Webhook(name: "", url: "") },
            set: { new in
                if let i = engine.config.webhooks.firstIndex(where: { $0.id == id }) { engine.config.webhooks[i] = new }
            }
        )
    }
}

struct WebhookEditor: View {
    @EnvironmentObject private var engine: RelayEngine
    @Binding var webhook: Webhook
    var onDelete: () -> Void

    @State private var editor = TemplateEditorController()
    @State private var pendingTemplate: MessageTemplate?
    @State private var savingName: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $webhook.name)
                TextField("地址", text: $webhook.url, prompt: Text("https://…"))
                Toggle("启用", isOn: $webhook.enabled)
                if let suggested = BuiltinTemplates.suggested(forURL: webhook.url),
                   webhook.template == BuiltinTemplates.genericJSON.body {
                    HStack {
                        Image(systemName: "lightbulb").foregroundStyle(.yellow)
                        Text("这是\(platformName(suggested))的地址，需要用它规定的消息格式。")
                        Spacer()
                        Button("套用“\(suggested.name)”") { webhook.template = suggested.body }
                    }
                    .font(.callout)
                }
            }

            Section {
                HStack {
                    templateMenu
                    Menu("插入字段") {
                        ForEach(NotificationField.allCases) { f in
                            Button("\(f.label)  {{\(f.rawValue)}}") { editor.insert(f) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("保存为常用模板…") { savingName = "" }
                }
                TemplateTextView(text: $webhook.template, controller: editor)
                    .frame(minHeight: 170)
                Text("输入 @ 会弹出通知字段列表，↑↓ 选择、回车插入。字段后面可以加格式，例如 {{date|datetime}} 显示成“11-09 00:17”，{{body|quote}} 把正文变成引用块；可用格式：time、date、datetime、quote、oneline。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("消息模板")
            }

            Section("预览（用示例通知填充）") {
                TemplatePreview(template: webhook.template)
            }

            Section {
                HStack {
                    Button("发送测试消息") { engine.sendTest(to: webhook) }
                        .disabled(webhook.url.isEmpty)
                    if let r = engine.testResults[webhook.id] {
                        Text(r.summary)
                            .font(.callout)
                            .foregroundStyle(r.ok ? .green : .red)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("删除 WebHook", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "用“\(pendingTemplate?.name ?? "")”替换当前模板？",
            isPresented: Binding(get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } })
        ) {
            Button("替换") {
                if let t = pendingTemplate { webhook.template = t.body }
                pendingTemplate = nil
            }
        } message: {
            Text("当前模板改过的内容会丢失。")
        }
        .confirmationDialog("删除“\(webhook.name)”？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
        } message: {
            Text("使用它的转发规则会同时移除这个目标。")
        }
        .alert("保存为常用模板", isPresented: Binding(get: { savingName != nil }, set: { if !$0 { savingName = nil } })) {
            TextField("模板名称", text: Binding(get: { savingName ?? "" }, set: { savingName = $0 }))
            Button("保存") {
                let name = (savingName ?? "").trimmingCharacters(in: .whitespaces)
                engine.config.templates.append(MessageTemplate(name: name.isEmpty ? "我的模板" : name, body: webhook.template))
                savingName = nil
            }
            Button("取消", role: .cancel) { savingName = nil }
        } message: {
            Text("保存后可以在其他 WebHook 里直接套用，也可以在“常用模板”页修改。")
        }
    }

    private var templateMenu: some View {
        Menu("套用模板") {
            Section("内置模板") {
                ForEach(BuiltinTemplates.all) { t in Button(t.name) { apply(t) } }
            }
            if !engine.config.templates.isEmpty {
                Section("我的模板") {
                    ForEach(engine.config.templates) { t in Button(t.name) { apply(t) } }
                }
            }
        }
        .fixedSize()
    }

    private func apply(_ t: MessageTemplate) {
        let known = (BuiltinTemplates.all + engine.config.templates).map(\.body)
        if webhook.template.isEmpty || known.contains(webhook.template) {
            webhook.template = t.body
        } else {
            pendingTemplate = t
        }
    }

    private func platformName(_ t: MessageTemplate) -> String {
        if t.id == BuiltinTemplates.wecomText.id { return "企业微信" }
        if t.id == BuiltinTemplates.feishuText.id { return "飞书" }
        if t.id == BuiltinTemplates.dingtalkText.id { return "钉钉" }
        return t.name
    }
}

/// 用示例通知渲染模板，显示结果或错误。
struct TemplatePreview: View {
    let template: String

    var body: some View {
        switch Result(catching: { try TemplateRenderer.render(template, with: WebhookSender.sampleRecord()) }) {
        case .success(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(msg.isJSON ? "JSON 格式正确" : "按纯文本发送", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(pretty(msg))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failure(let error):
            Label(String(describing: error), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func pretty(_ msg: RenderedMessage) -> String {
        guard msg.isJSON,
              let obj = try? JSONSerialization.jsonObject(with: msg.body),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: msg.body, as: UTF8.self) }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 常用模板页

struct TemplatesView: View {
    @EnvironmentObject private var engine: RelayEngine
    @State private var creating: MessageTemplate?
    @State private var expanded: UUID?

    var body: some View {
        Form {
            Section {
                if engine.config.templates.isEmpty {
                    Text("还没有自己的模板。可以复制下面的内置模板来改，或在 WebHook 页“保存为常用模板”。")
                        .foregroundStyle(.secondary)
                }
                ForEach(engine.config.templates) { t in
                    MyTemplateRow(
                        template: binding(t.id),
                        expanded: Binding(get: { expanded == t.id }, set: { expanded = $0 ? t.id : nil })
                    ) {
                        engine.config.templates.removeAll { $0.id == t.id }
                    }
                }
            } header: {
                HStack {
                    Text("我的模板")
                    Spacer()
                    Button("新建模板…", systemImage: "plus") {
                        creating = MessageTemplate(name: "", body: BuiltinTemplates.genericJSON.body)
                    }
                }
            }

            Section("内置模板") {
                ForEach(BuiltinTemplates.all) { t in
                    DisclosureGroup(isExpanded: expandedBinding(t.id)) {
                        TemplateTextView(text: .constant(t.body), isEditable: false)
                            .frame(height: 150)
                    } label: {
                        HStack {
                            Text(t.name)
                            Spacer()
                            Button("复制为我的模板") {
                                creating = MessageTemplate(name: t.name + "（副本）", body: t.body)
                            }
                        }
                        .clickToToggle(expandedBinding(t.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("常用模板")
        .sheet(item: $creating) { draft in
            NewTemplateSheet(draft: draft) { t in
                engine.config.templates.append(t)
                expanded = t.id
            }
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded == id }, set: { expanded = $0 ? id : nil })
    }

    private func binding(_ id: UUID) -> Binding<MessageTemplate> {
        Binding(
            get: { engine.config.templates.first { $0.id == id } ?? MessageTemplate(name: "", body: "") },
            set: { new in
                if let i = engine.config.templates.firstIndex(where: { $0.id == id }) { engine.config.templates[i] = new }
            }
        )
    }
}

private struct MyTemplateRow: View {
    @Binding var template: MessageTemplate
    @Binding var expanded: Bool
    var onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模板名称").font(.caption).foregroundStyle(.secondary)
                    TextField("模板名称", text: $template.name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("内容（输入 @ 插入通知字段）").font(.caption).foregroundStyle(.secondary)
                    TemplateTextView(text: $template.body)
                        .frame(minHeight: 160)
                }
                TemplatePreview(template: template.body)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(template.name.isEmpty ? "未命名模板" : template.name)
                Spacer()
                Button(expanded ? "收起" : "编辑") { withAnimation { expanded.toggle() } }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("删除模板")
            }
            .clickToToggle($expanded)
        }
        .confirmationDialog("删除模板“\(template.name)”？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
        } message: {
            Text("已经用这个模板的 WebHook 不受影响。")
        }
    }
}

/// 新建模板：先起名字、选从哪个模板开始，再创建。
private struct NewTemplateSheet: View {
    @State var draft: MessageTemplate
    var onCreate: (MessageTemplate) -> Void
    @EnvironmentObject private var engine: RelayEngine
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建模板").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                TextField("例如：企业微信 · 带时间", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("从哪个模板开始")
                Menu(startName) {
                    ForEach(BuiltinTemplates.all) { t in
                        Button(t.name) { draft.body = t.body }
                    }
                    Divider()
                    Button("空白") { draft.body = "{\n  \n}" }
                }
                .fixedSize()
            }
            TemplatePreview(template: draft.body)
                .frame(maxHeight: 180, alignment: .top)
                .clipped()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    var t = draft
                    t.name = t.name.trimmingCharacters(in: .whitespaces)
                    onCreate(t)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .prominentGlassButton()
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private var startName: String {
        BuiltinTemplates.all.first { $0.body == draft.body }?.name ?? (draft.body == "{\n  \n}" ? "空白" : "自定义内容")
    }
}

extension View {
    /// 让整行（标题和空白处）都能点击展开/收起；行里的按钮照常响应自己的点击。
    func clickToToggle(_ expanded: Binding<Bool>) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.wrappedValue.toggle() } }
    }
}
