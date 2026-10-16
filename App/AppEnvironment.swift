import AppKit
import Observation
import SwiftUI
import WidgetKit

/// 全局依赖容器。视图通过 `.environment(_:)` 拿到它。
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let store: QuotaStore

    /// 阻止 App Nap。窗口关掉后应用转入后台，macOS 默认会把后台应用的
    /// 定时器合并 throttling，轮询会被拖慢——而用户明确要求关掉面板后
    /// 小组件仍然实时刷新，所以这里显式声明「别睡」。
    private var antiNapActivity: (any NSObjectProtocol)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = QuotaStore(settings: settings)

        store.onWidgetDataChanged = {
            WidgetCenter.shared.reloadAllTimelines()
        }

        antiNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "保持额度轮询，使桌面小组件在窗口关闭后仍实时刷新")

        observeSystemEvents()

        Task { @MainActor [store] in
            await store.refreshAll()
            store.startLiveRefresh()
        }
    }

    /// 回到前台、系统唤醒时立刻刷一次，不等下一轮轮询。
    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        })
    }

    /// 刷新额度；拿到新数据后由 store 的回调通知系统重画小组件。
    func refresh() async {
        await store.refreshAll()
    }

    /// 启用列表变化后重建轮询循环。
    func providersDidChange() {
        store.restartLiveRefresh()
        Task { await refresh() }
    }
}