import AppKit
import SwiftUI
import RelayCore

// MARK: - 权限页

struct AccessView: View {
    @EnvironmentObject private var engine: RelayEngine
    @State private var showDetails = false
    @State private var confirmRevoke = false

    private var granted: Bool { engine.access == .ok }

    var body: some View {
        Form {
            Section {
                header
            }

            if granted {
                Section("状态") {
                    LabeledContent("读取方式") {
                        Text(FolderGrant.hasSavedGrant ? "只读取通知文件夹" : "完全磁盘访问权限")
                    }
                    LabeledContent("通知数据库") {
                        Label("已连接，正在读取新通知", systemImage: "circle.fill")
                            .labelStyle(StatusDotLabelStyle(color: .green))
                    }
                    LabeledContent("转发") {
                        if engine.config.forwardingEnabled {
                            Label("进行中", systemImage: "circle.fill").labelStyle(StatusDotLabelStyle(color: .green))
                        } else {
                            Label("已暂停，新通知只记录不发送", systemImage: "circle.fill").labelStyle(StatusDotLabelStyle(color: .orange))
                        }
                    }
                    LabeledContent("本次启动后转发") {
                        Text("\(engine.forwardedCount) 条").monospacedDigit()
                    }
                }
            } else {
                Section {
                    MethodRow(
                        icon: "folder.badge.gearshape",
                        title: "只允许读取通知文件夹",
                        badge: "推荐",
                        text: "弹出的窗口已经定位好，直接点「授权」。捎信只能看到存放通知的这一个文件夹。"
                    ) {
                        Button("授权读取通知…") { pickFolder() }
                            .prominentGlassButton()
                    }
                }
                Section {
                    MethodRow(
                        icon: "lock.shield",
                        title: "打开完全磁盘访问权限",
                        badge: nil,
                        text: "上面的方式不起作用时再用。把屏幕上出现的捎信图标拖进系统设置的列表，再打开开关。"
                    ) {
                        Button("打开系统设置") { AccessGuide.shared.start(engine: engine) }
                    }
                }
            }

            Section {
                DisclosureGroup("技术细节", isExpanded: $showDetails) {
                    LabeledContent("通知数据库") {
                        Text(engine.databasePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(engine.databasePath)
                    }
                    if case .denied(let msg) = engine.access {
                        LabeledContent("系统返回") { Text(msg).textSelection(.enabled) }
                    }
                    ScrollView {
                        Text(engine.diagnostics.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 140)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack {
                        if FolderGrant.hasSavedGrant {
                            Button("撤销文件夹授权…", role: .destructive) { confirmRevoke = true }
                        }
                        Spacer()
                        Button("复制记录") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(engine.diagnostics.joined(separator: "\n"), forType: .string)
                        }
                        Button("重新检测") { engine.retryAccess() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("权限")
        .confirmationDialog("撤销文件夹授权？", isPresented: $confirmRevoke) {
            Button("撤销", role: .destructive) {
                FolderGrant.clear()
                engine.note("已撤销文件夹授权")
                engine.retryAccess()
            }
        } message: {
            Text("撤销后捎信读不到通知，转发会停止，需要重新授权。")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, granted ? Color.green : Color.orange)
                    .background(Circle().fill(.background).padding(2))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(granted ? "已经可以读取通知" : "允许捎信读取通知")
                    .font(.title3.weight(.semibold))
                Text(granted
                     ? (engine.config.forwardingEnabled
                        ? "捎信在后台留意新通知，并按你设置的规则转发。"
                        : "转发已暂停。新通知仍会出现在「最近通知」里，但不会发送。")
                     : "macOS 不让 App 互相查看通知，需要你允许一次。下面两种方式选一种就行。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = FolderGrant.suggestedDirectory
        panel.message = "已经打开在存放通知的文件夹里，直接点「授权」即可。"
        panel.prompt = "授权"
        panel.accessoryView = FolderPanelAccessory.make()
        panel.isAccessoryViewDisclosed = true
        panel.delegate = FolderPanelDelegate.shared
        engine.note("打开授权窗口：\(FolderGrant.suggestedDirectory.path)")
        guard panel.runModal() == .OK, let url = panel.url else {
            engine.note("取消了授权")
            return
        }
        engine.note("授权了：\(url.path)")
        engine.grantFolder(url)
    }
}

/// 一种授权方式：左边图标，中间说明，右边按钮。
private struct MethodRow<Action: View>: View {
    let icon: String
    let title: String
    let badge: String?
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(.vertical, 4)
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

/// 选择窗口：只允许授权通知文件夹，选错了当场提示，不关窗口。
final class FolderPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    static let shared = FolderPanelDelegate()

    /// 只有通知文件夹本身和它的上一层可以点；其他文件夹变灰。
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        FolderGrant.isAcceptable(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard FolderGrant.isAcceptable(url) else {
            throw NSError(domain: "SendWord", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "这不是存放通知的文件夹",
                NSLocalizedRecoverySuggestionErrorKey: "请回到「db2」文件夹里，什么都不用选，直接点「授权」。",
            ])
        }
    }
}

/// 选择窗口底部的说明条。
enum FolderPanelAccessory {
    @MainActor
    static func make() -> NSView {
        let host = NSHostingView(rootView:
            HStack(spacing: 10) {
                Image(systemName: "hand.point.right.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已经帮你定位好了，直接点右下角的「授权」").font(.headline)
                    Text("不用选文件，也不用换文件夹。捎信只会读取这里的通知记录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 560)
        )
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        return host
    }
}



// MARK: - Liquid Glass 兼容封装（macOS 26 起用玻璃样式，旧系统退回到常规样式）

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 拖拽授权引导

/// 打开系统设置的「完全磁盘访问权限」，并在旁边放一个可以拖动的 App 图标，拖进列表即可添加。
@MainActor
final class AccessGuide {
    static let shared = AccessGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private weak var engine: RelayEngine?
    private let model = GuideModel()

    func start(engine: RelayEngine) {
        self.engine = engine
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        model.granted = false
        showPanel()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        guard let engine else { stop(); return }
        engine.retryAccess()
        if engine.access == .ok {
            model.granted = true
            timer?.invalidate()
            timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.panel?.orderOut(nil) }
            return
        }
        positionPanel()
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: GuideView(
            model: model,
            close: { [weak self] in self?.stop() },
            relaunch: { AccessGuide.relaunch() }
        ))
        return panel
    }

    /// 放到系统设置窗口下方；找不到系统设置窗口时放在屏幕下方居中。
    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80)
        if let settings = Self.systemSettingsWindowFrame() {
            // CGWindow 坐标以主屏左上角为原点，换算成 AppKit 坐标（左下角原点）。
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let bottom = primaryHeight - settings.maxY
            origin = NSPoint(x: settings.midX - size.width / 2, y: bottom - size.height - 12)
            if origin.y < screen.visibleFrame.minY + 8 {
                // 下方放不下就放到右侧。
                origin = NSPoint(x: settings.maxX + 12, y: primaryHeight - settings.midY - size.height / 2)
            }
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private static func systemSettingsWindowFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.systempreferences",
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 300
            else { continue }
            return rect
        }
        return nil
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        // 新实例稍等旧实例退出后再启动。
        let task = DispatchWorkItem { NSWorkspace.shared.openApplication(at: url, configuration: config) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: task)
    }
}

final class GuideModel: ObservableObject {
    @Published var granted = false
}

private struct GuideView: View {
    @ObservedObject var model: GuideModel
    let close: () -> Void
    let relaunch: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if model.granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("授权成功").font(.headline)
                    Text("捎信已经可以读取通知了。").foregroundStyle(.secondary)
                }
            } else {
                DraggableAppIcon()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Label("把图标拖进上方的 App 列表", systemImage: "arrow.up")
                        .font(.headline)
                    Text("然后打开捎信的开关。")
                        .foregroundStyle(.secondary)
                    Button("已打开开关但没生效？重新启动捎信", action: relaunch)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 400, height: 112)
        .glassCard(cornerRadius: 22)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .padding(10)
            .help("关闭引导")
        }
    }
}

/// 可以拖出去的 App 图标，拖动内容是 SendWord.app 本身的文件地址。
private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ nsView: DragSourceView, context: Context) {}

    final class DragSourceView: NSView, NSDraggingSource {
        private let icon = NSApp.applicationIconImage ?? NSImage()
        private var hovering = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let inset: CGFloat = hovering ? 0 : 3
            icon.draw(in: bounds.insetBy(dx: inset, dy: inset))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
        override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
