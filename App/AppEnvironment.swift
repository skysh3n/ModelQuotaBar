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

    /// 阻止 App Nap。后台时 macOS 默认会合并延迟定时器，事件触发的去抖刷新
    /// 可能被拖慢，这里显式声明「别睡」，保证切到桌面瞬间能拿到最新数据。
    private var antiNapActivity: (any NSObjectProtocol)?
    private var observers: [NSObjectProtocol] = []
    private var debouncedRefreshTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = QuotaStore(settings: settings)

        store.onWidgetDataChanged = {
            WidgetCenter.shared.reloadAllTimelines()
        }

        antiNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "保持事件触发的额度刷新及时执行，使桌面小组件实时更新")

        observeSystemEvents()

        Task { @MainActor [store] in
            await store.refreshAll()
        }
    }

    /// 事件驱动的即时刷新。多个系统事件往往在几百毫秒内接连触发
    /// （比如唤醒 → 回到前台 → 切换空间），去抖合并成一次请求。
    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleImmediateRefresh() }
        }

        // 切换空间 / 切到桌面（activeSpaceDidChange 正是这个语义）。
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main, using: refresh))
        // 系统唤醒。
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: refresh))
        // 解锁回到会话。
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main, using: refresh))
        // 应用回到前台。
        observers.append(appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: refresh))
    }

    private func scheduleImmediateRefresh() {
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// 刷新额度；拿到新数据后由 store 的回调通知系统重画小组件。
    func refresh() async {
        await store.refreshAll()
    }

    /// 启用列表变化后，对齐结果并立即刷一次。
    func providersDidChange() {
        store.syncWithSettings()
        Task { await refresh() }
    }
}