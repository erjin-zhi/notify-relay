import AppKit
import SwiftUI
import RelayCore

/// 让外面的按钮（比如“插入字段”菜单）往编辑器光标处插入内容。
final class TemplateEditorController {
    fileprivate weak var textView: NSTextView?

    func insert(_ field: NotificationField) {
        guard let textView else { return }
        let token = "{{\(field.rawValue)}}"
        var range = textView.selectedRange()
        if range.location == NSNotFound || range.location > (textView.string as NSString).length {
            range = NSRange(location: (textView.string as NSString).length, length: 0)
        }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(token, replacementRange: range)
    }
}

/// 模板编辑框：输入 @ 弹出通知字段列表，↑↓ 选择，回车或 Tab 插入 `{{字段}}`，Esc 关闭。
/// 占位符会高亮，写错的字段名标红。
struct TemplateTextView: NSViewRepresentable {
    @Binding var text: String
    var controller: TemplateEditorController? = nil
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 用 TextKit 1：TextKit 2 按行分图层绘制，嵌在 SwiftUI 表单里时行与行之间会露出细横线。
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = isEditable
        // 智能引号、破折号替换会把 JSON 改坏，全部关掉。
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.font = Coordinator.font
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = text
        context.coordinator.textView = tv
        controller?.textView = tv
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller?.textView = tv
        tv.isEditable = isEditable
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight()
        }
    }

    /// 直接按父视图给的空间取尺寸，不让系统用自动布局去测量滚动视图（侧边栏动画时每帧都会测，很慢）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 170)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.picker.hide()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        var parent: TemplateTextView
        weak var textView: NSTextView?
        let picker = FieldPicker()
        /// 当前 `@查询词` 在文本里的位置（包括 @）。
        private var triggerRange: NSRange?

        init(_ parent: TemplateTextView) {
            self.parent = parent
            super.init()
            picker.onPick = { [weak self] field in self?.accept(field) }
        }

        // MARK: 文本变化

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
            updateTrigger(openIfNeeded: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateTrigger(openIfNeeded: false)
        }

        func textDidEndEditing(_ notification: Notification) {
            picker.hide()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard picker.isVisible else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): picker.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): picker.move(1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let f = picker.selectedField { accept(f) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                picker.hide(); triggerRange = nil; return true
            default: return false
            }
        }

        // MARK: @ 触发

        private func updateTrigger(openIfNeeded: Bool) {
            guard let tv = textView, tv.isEditable else { picker.hide(); return }
            let sel = tv.selectedRange()
            guard sel.length == 0, let range = Self.findTrigger(in: tv.string as NSString, caret: sel.location) else {
                triggerRange = nil
                picker.hide()
                return
            }
            if !picker.isVisible && !openIfNeeded { return }
            triggerRange = range
            let query = (tv.string as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1))
            let fields = Self.filter(query)
            guard !fields.isEmpty else { picker.hide(); return }
            let caretRect = tv.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
            picker.show(fields: fields, below: caretRect, parent: tv.window)
        }

        /// 从光标往前找 `@`：中间不能有空白、引号或括号；`@` 前面是英文字母或数字时（像邮箱地址）不触发。
        static func findTrigger(in s: NSString, caret: Int) -> NSRange? {
            var i = caret - 1
            let stop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'{}[]@,:"))
            while i >= 0 && caret - i <= 24 {
                let ch = s.character(at: i)
                if ch == 0x40 { // @
                    if i > 0 {
                        let prev = s.character(at: i - 1)
                        if (0x30...0x39).contains(prev) || (0x41...0x5A).contains(prev) || (0x61...0x7A).contains(prev) { return nil }
                    }
                    return NSRange(location: i, length: caret - i)
                }
                if let scalar = Unicode.Scalar(ch), stop.contains(scalar) { return nil }
                i -= 1
            }
            return nil
        }

        static func filter(_ query: String) -> [NotificationField] {
            let q = query.lowercased()
            guard !q.isEmpty else { return NotificationField.allCases }
            return NotificationField.allCases.filter {
                $0.label.lowercased().contains(q) || $0.rawValue.lowercased().contains(q)
            }
        }

        private func accept(_ field: NotificationField) {
            guard let tv = textView, let range = triggerRange else { return }
            triggerRange = nil
            picker.hide()
            tv.insertText("{{\(field.rawValue)}}", replacementRange: range)
        }

        // MARK: 高亮

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor], range: full)
            for (range, name) in TemplateRenderer.placeholders(in: storage.string) {
                let known = TemplateRenderer.isValidPlaceholder(name)
                let color: NSColor = known ? .systemBlue : .systemRed
                storage.addAttributes([
                    .foregroundColor: color,
                    .backgroundColor: color.withAlphaComponent(0.12),
                ], range: range)
            }
            storage.endEditing()
        }
    }
}

// MARK: - 字段选择浮层

@MainActor
final class FieldPicker {
    final class Model: ObservableObject {
        @Published var fields: [NotificationField] = []
        @Published var selected = 0
    }

    var onPick: ((NotificationField) -> Void)?
    private let model = Model()
    private var panel: NSPanel?
    private static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 280

    var isVisible: Bool { panel?.isVisible ?? false }

    var selectedField: NotificationField? {
        model.fields.indices.contains(model.selected) ? model.fields[model.selected] : nil
    }

    func move(_ delta: Int) {
        guard !model.fields.isEmpty else { return }
        model.selected = (model.selected + delta + model.fields.count) % model.fields.count
    }

    func show(fields: [NotificationField], below caretRect: NSRect, parent: NSWindow?) {
        if fields != model.fields { model.selected = 0 }
        model.fields = fields
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = CGFloat(min(fields.count, 9)) * Self.rowHeight + 8
        var frame = NSRect(x: caretRect.minX, y: caretRect.minY - height - 2, width: Self.width, height: height)
        if let screen = parent?.screen?.visibleFrame, frame.minY < screen.minY {
            frame.origin.y = caretRect.maxY + 2 // 下方放不下就放到上方
        }
        panel.setFrame(frame, display: true)
        if let parent, panel.parent != parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        let list = FieldPickerList(model: model, rowHeight: Self.rowHeight) { [weak self] f in self?.onPick?(f) }
        panel.contentView = NSHostingView(rootView: list)
        return panel
    }
}

private struct FieldPickerList: View {
    @ObservedObject var model: FieldPicker.Model
    let rowHeight: CGFloat
    let pick: (NotificationField) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.fields.enumerated()), id: \.element) { i, f in
                        HStack {
                            Text(f.label)
                            Spacer()
                            Text("{{\(f.rawValue)}}")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(i == model.selected ? Color.white.opacity(0.85) : .secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: rowHeight)
                        .foregroundStyle(i == model.selected ? Color.white : Color.primary)
                        .background(i == model.selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { pick(f) }
                        .id(i)
                    }
                }
                .padding(4)
            }
            .onChange(of: model.selected) { _, i in proxy.scrollTo(i) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}
