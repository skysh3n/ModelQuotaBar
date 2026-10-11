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

        Task { @MainActor [store] in
            await store.refreshAll()
            store.startAutoRefresh()
        }
    }

    /// 刷新额度，并在拿到新数据后让系统重画小组件。
    func refresh() async {
        await store.refreshAll()
        WidgetCenter.shared.reloadAllTimelines()
    }
}