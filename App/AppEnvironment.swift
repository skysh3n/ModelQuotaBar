import Observation
import SwiftUI
import WidgetKit

/// 全局依赖容器。视图通过 `.environment(_:)` 拿到它。
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let store: QuotaStore

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = QuotaStore(settings: settings)

        store.onWidgetDataChanged = {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // 不在启动时自动刷新：只等用户点「刷新」（或改用来源后的 providersDidChange）。
    }

    // MARK: - 刷新

    func refresh() async {
        await store.refreshAll()
    }

    /// 启用列表变化后，对齐结果并立即刷一次。
    func providersDidChange() {
        store.syncWithSettings()
        Task { await refresh() }
    }
}
