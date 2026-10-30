import AppIntents
import Foundation

/// 小组件刷新按钮的 App Intent。
///
/// **只编进 QuotaWidget target**，不要进主应用：双 target 时系统会在主应用仍存活
/// （或被拉起）时于主进程执行 intent，macOS 上就会弹出主窗口。扩展独占则可
/// 保证一直在小组件进程里跑，配合 `openAppWhenRun = false`。
///
/// **不要带 `@Parameter`**：带参 intent 在 macOS 桌面小组件归档时可能绑不上按钮，
/// 表现就是看得见刷新图标，但 AX 没有 Button、点击落到系统默认「打开主应用」，
/// 且 `perform` 根本不会跑。
struct RefreshQuotaIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新额度"
    static var openAppWhenRun: Bool { false }
    /// 不进 Shortcuts / Siri 目录，避免从别处触发时打开主应用。
    static var isDiscoverable: Bool { false }

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

    /// 写入小组件容器，供本机验证「intent 是否真的跑过」（沙盒 home 即容器）。
    private static func trace(_ message: String) {
        let dir = SharedStore.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir else { return }
        let url = dir.appendingPathComponent("refresh-intent.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
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
}
