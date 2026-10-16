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
    /// 后台会话保活：定期用网页登录态访问一次控制台，让会话续期。
    let sessionKeeper = WebSessionKeeper()

    /// 需要用户登录的来源。非 nil 时界面会自动弹出登录窗口。
    var pendingLogin: (provider: ProviderID, spec: WebLoginSpec)?

    private var observers: [NSObjectProtocol] = []
    private var debouncedRefreshTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = QuotaStore(settings: settings)

        store.onWidgetDataChanged = {
            WidgetCenter.shared.reloadAllTimelines()
        }

        sessionKeeper.onCredentialRefreshed = { [weak self] _ in
            // 保活取回了新票，立刻用它刷一次数据。
            Task { @MainActor [weak self] in await self?.refresh() }
        }

        observeSystemEvents()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            self.startSessionKeeperIfNeeded()
            self.presentLoginIfNeeded()
        }
    }

    // MARK: - 刷新

    func refresh() async {
        await store.refreshAll()
        await recoverExpiredSessions()
    }

    /// 会话过期时先用保活会话自动续期并重试；续不上再请用户登录。
    private func recoverExpiredSessions() async {
        guard let expired = expiredLoginSpec() else { return }
        if sessionKeeper.isRunning {
            await sessionKeeper.refreshNow()
            await store.refreshAll()
            // 续期成功就不再打扰用户。
            if expiredLoginSpec() == nil { return }
        }
        pendingLogin = expired
    }

    /// 找出第一个「可以用网页登录解决」的过期来源。
    private func expiredLoginSpec() -> (provider: ProviderID, spec: WebLoginSpec)? {
        for provider in settings.activeProviders {
            guard let spec = provider.metadata.webLogin,
                  let error = store.results.first(where: { $0.id == provider.id })?.error,
                  case .sessionExpired = error
            else { continue }
            return (provider.id, spec)
        }
        return nil
    }

    /// 启用了「登录获取」的来源才有可续期的网页登录态，保活才有意义。
    private func startSessionKeeperIfNeeded() {
        guard sessionKeeper.isRunning == false else { return }
        for provider in settings.activeProviders
        where settings.webLoginProviderIDs.contains(provider.id) {
            guard let spec = provider.metadata.webLogin else { continue }
            sessionKeeper.start(target: .init(providerID: provider.id, spec: spec))
            return
        }
    }

    /// 凭据失效能用网页登录解决时，直接把登录窗口推给用户。
    private func presentLoginIfNeeded() {
        guard pendingLogin == nil else { return }
        pendingLogin = expiredLoginSpec()
    }

    /// 登录窗口拿到凭据后调用。
    func didCaptureLogin(provider: ProviderID) {
        settings.markWebLoginUsed(provider)
        pendingLogin = nil
        startSessionKeeperIfNeeded()
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
