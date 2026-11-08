import AppKit

/// 数据库里只有 Bundle ID，这里查出 App 的显示名，比如 `com.tencent.xinWeChat` → “微信”。
@MainActor
public final class AppNameResolver {
    public static let shared = AppNameResolver()
    private var cache: [String: String] = [:]

    public func name(for bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        cache[bundleID] = name
        return name
    }

    public func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
