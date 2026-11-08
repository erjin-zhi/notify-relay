import Foundation

/// “只授权通知文件夹”：用户在选择文件夹窗口里选中通知数据库所在文件夹后，
/// 保存一份安全书签，以后启动时恢复访问，不用再选。
public enum FolderGrant {
    private static let defaultsKey = "notificationFolderBookmark"
    private static var activeURL: URL?

    /// 通知数据库所在的文件夹（…/group.com.apple.usernoted/db2）。
    public static var notificationFolder: URL {
        URL(fileURLWithPath: NotificationStore.defaultPath).deletingLastPathComponent()
    }

    /// 选择窗口直接打开在 db2 里面：用户不用找，点「授权」就是选中当前文件夹。
    public static var suggestedDirectory: URL { notificationFolder }

    public static var hasSavedGrant: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }

    public enum GrantError: Error, CustomStringConvertible {
        case wrongFolder(String)
        case bookmark(String)

        public var description: String {
        switch self {
            case .wrongFolder(let p): return "“\(p)”不是通知所在的文件夹。请重新打开选择窗口，直接点「授权」。"
            case .bookmark(let m): return "无法记住这个文件夹：\(m)"
            }
        }
    }

    /// 能用来授权的文件夹：db2，或它的上一层 group.com.apple.usernoted。
    public static func isAcceptable(_ url: URL) -> Bool {
        let chosen = url.resolvingSymlinksInPath().standardizedFileURL.path
        let target = notificationFolder.resolvingSymlinksInPath().standardizedFileURL.path
        return chosen.contains("group.com.apple.usernoted")
            && (target == chosen || target.hasPrefix(chosen.hasSuffix("/") ? chosen : chosen + "/"))
    }

    public static func save(_ url: URL) throws {
        guard isAcceptable(url) else { throw GrantError.wrongFolder(url.lastPathComponent) }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            throw GrantError.bookmark(error.localizedDescription)
        }
        stop()
        if url.startAccessingSecurityScopedResource() { activeURL = url }
    }

    /// 启动时恢复访问。返回一行说明，供诊断信息显示。
    @discardableResult
    public static func restore() -> String {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return "没有保存过文件夹授权" }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            stop()
            let ok = url.startAccessingSecurityScopedResource()
            if ok { activeURL = url }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: defaultsKey)
            }
            return ok ? "已恢复文件夹授权：\(url.path)" : "文件夹授权恢复失败：系统拒绝访问 \(url.path)"
        } catch {
            return "文件夹授权恢复失败：\(error.localizedDescription)"
        }
    }

    public static func clear() {
        stop()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func stop() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }
}
