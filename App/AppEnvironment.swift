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
        // 有本地缓存就先出界面，不自动请求；只有完全没缓存（首次启动/缓存文件丢失）
        // 才补拉一次，避免打开应用只看到一屏空卡片。
        if !store.hasCachedData {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
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
