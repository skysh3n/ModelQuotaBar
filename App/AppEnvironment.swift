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

    private var observers: [NSObjectProtocol] = []
    private var debouncedRefreshTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = QuotaStore(settings: settings)

        store.onWidgetDataChanged = {
            WidgetCenter.shared.reloadAllTimelines()
        }

        observeSystemEvents()

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

    // MARK: - 系统事件

    /// 事件驱动的即时刷新。多个系统事件往往在几百毫秒内接连触发
    /// （比如唤醒 → 回到前台 → 切换空间），去抖合并成一次请求。
    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleImmediateRefresh() }
        }

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main, using: refresh))
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: refresh))
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main, using: refresh))
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

    /// 启用列表变化后，对齐结果并立即刷一次。
    func providersDidChange() {
        store.syncWithSettings()
        Task { await refresh() }
    }
}
