import SwiftUI
import AppKit
import RelayCore

/// 一条转发记录的详情：原始通知、发给 WebHook 的请求原文、平台返回的内容。
struct DeliveryDetailView: View {
    let entry: DeliveryLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("概要") {
                    LabeledContent("时间", value: entry.time.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("转发到", value: entry.result.webhookName)
                    LabeledContent("结果") {
                        Text(entry.result.summary).foregroundStyle(entry.result.ok ? .green : .red)
                    }
                    if let d = entry.result.duration {
                        LabeledContent("耗时", value: "\(Int((d * 1000).rounded())) ms")
                    }
                    if let req = entry.result.request {
                        LabeledContent("调试") {
                            CopyButton(title: "复制 cURL", text: req.curlCommand)
                                .help("复制成 curl 命令，在终端里重发同样的请求")
                        }
                    }
                }

                Section {
                    if let req = entry.result.request {
                        LabeledContent("地址") {
                            Text("\(req.method) \(req.url)")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        LabeledContent("Content-Type", value: req.contentType)
                        CodeBlock(text: req.body)
                    } else {
                        Text("请求没有发出：\(entry.result.error ?? "未知原因")").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("发送内容")
                        Spacer()
                        if let body = entry.result.request?.body {
                            CopyButton(text: body)
                        }
                    }
                }

                if entry.result.request != nil {
                    Section {
                        LabeledContent("HTTP 状态", value: entry.result.statusCode.map(String.init) ?? "无")
                        if let text = entry.result.responseBody, !text.isEmpty {
                            CodeBlock(text: text)
                        } else {
                            Text("没有返回内容").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text("平台返回")
                            Spacer()
                            if let text = entry.result.responseBody, !text.isEmpty {
                                CopyButton(text: text)
                            }
                        }
                    }
                }

                Section("原始通知") {
                    ForEach(fields, id: \.0) { label, value in
                        LabeledContent(label) {
                            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 640, idealHeight: 720)
    }

    /// 通知里有值的字段。
    private var fields: [(String, String)] {
        NotificationField.allCases.compactMap { f in
            guard let v = entry.record.value(for: f), !v.isEmpty else { return nil }
            return (f.label, v)
        }
    }
}

/// 等宽显示的原文，和实际发送/收到的内容一字不差，长行自动换行。
private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 44, maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 把原文复制到剪贴板。
private struct CopyButton: View {
    var title = "复制"
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("复制原文")
    }
}
