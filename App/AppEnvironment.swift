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

        // 只在打开时拉一次。回到前台、切桌面、唤醒都不再自动刷新，之后用手动刷新。
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - 刷新

    func refresh() async {
        await store.refreshAll()
    }

    /// 登录窗口拿到凭据后调用。
    func didCaptureLogin() {
        Task { await refresh() }
    }

    /// 启用列表变化后，对齐结果并立即刷一次。
    func providersDidChange() {
        store.syncWithSettings()
        Task { await refresh() }
    }
}
