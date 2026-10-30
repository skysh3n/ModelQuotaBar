import AppIntents
import Foundation

/// 小组件刷新按钮的 App Intent。
///
/// **必须同时编进 App + QuotaWidget**（Apple 对 widget `AppIntent` 的要求）：
/// 只进扩展时，macOS 桌面小组件上的 `Button(intent:)` 往往归档成不可交互，
/// 点击落到系统默认「打开主应用」，`perform` 也不会跑。
///
/// 双 target 时的进程选择：
/// - 主应用**未在跑**：在扩展进程执行（不会弹主窗口）
/// - 主应用已在跑：在主应用进程执行；靠 `openAppWhenRun = false` 不把窗口拉到前台
///
/// **不要带 `@Parameter`**：带参 intent 在 macOS 上更容易绑钮失败。
struct RefreshQuotaIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新额度"
    static var openAppWhenRun: Bool { false }
    /// 不进 Shortcuts / Siri 目录，避免从别处触发时打开主应用。
    /// 仍保持可被系统解析；不进 Shortcuts 目录主要靠不声明短语。
    static var isDiscoverable: Bool { true }

    func perform() async throws -> some IntentResult {
        Self.trace("perform-begin")
        let available = WidgetSource.availableSources()
        let sources = available.isEmpty ? Array(WidgetSource.allCases) : available
        let ids = Set(sources.map(\.rawValue))
        let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: ids)
        SharedStore.saveMerging(fresh)
        WidgetReloader.reload()
        Self.trace("perform-end ids=\(ids.sorted()) fresh=\(fresh.count)")
        return .result()
    }

    /// 写入共享容器，供本机验证「intent 是否真的跑过」。
    private static func trace(_ message: String) {
        let dir = SharedStore.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir else { return }
        let url = dir.appendingPathComponent("refresh-intent.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url)
        {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
