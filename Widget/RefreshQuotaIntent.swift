import AppIntents
import Foundation

/// 小组件刷新按钮的 App Intent。
///
/// **只编进 QuotaWidget target**，不要进主应用：双 target 时系统会在主应用仍存活
/// （或被拉起）时于主进程执行 intent，macOS 上就会弹出主窗口。扩展独占则可
/// 保证一直在小组件进程里跑，配合 `openAppWhenRun = false`。
struct RefreshQuotaIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新额度"
    static var openAppWhenRun: Bool = false
    /// 不进 Shortcuts / Siri 目录，避免从别处触发时打开主应用。
    static var isDiscoverable: Bool = false

    @Parameter(title: "显示来源", default: [.qwen, .deepseek, .cursor])
    var sources: [WidgetSource]

    init() {}

    init(sources: [WidgetSource]) {
        self.init()
        self.sources = sources
    }

    func perform() async throws -> some IntentResult {
        let ids = Set(WidgetSource.effectiveDisplaySources(sources).map(\.rawValue))
        let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: ids)
        SharedStore.saveMerging(fresh)
        WidgetReloader.reload()
        return .result()
    }
}
