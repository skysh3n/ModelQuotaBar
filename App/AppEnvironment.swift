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
        // 重装/升级后系统可能还挂着旧的小组件时间线，启动时主动让 WidgetKit 重新取一次。
        WidgetCenter.shared.reloadAllTimelines()
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

    /// 启用列表变化后，先让小组件丢掉已关闭的来源，再补一轮数据。
    func providersDidChange() {
        store.alignWidgetWithSettings()
        // 小组件扩展可能自己抓过已关闭的来源，缓存内容没变也要重画时间线。
        WidgetCenter.shared.reloadAllTimelines()
        Task { await refresh() }
    }
}
