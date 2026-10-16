import Foundation
import Observation

/// 单个 Provider 的一次查询结果。
public struct ProviderResult: Sendable, Identifiable {
    public let id: ProviderID
    public let metadata: ProviderMetadata
    public var snapshot: QuotaSnapshot?
    public var error: QuotaError?
    public var isLoading: Bool
    /// 上次成功拉取的时间。查询失败时保留，便于继续展示旧数据。
    public var lastSuccessAt: Date?

    public var isConfigured: Bool {
        snapshot != nil || error != nil
    }
}

/// 额度查询的调度中心。
///
/// 刷新模型是「事件驱动 + 每个源各自节奏的轮询」，而不是全局定时器：
/// - 应用回到前台、系统唤醒时立即刷一次；
/// - 每个 Provider 按自己的 `refreshInterval` 轮询（DeepSeek 余额接口轻，5 秒一次，
///   做到近似实时；千问走控制台网关，保守一些）；
/// - 服务端没有推送能力，轮询是逼近「实时」的唯一手段。
@MainActor
@Observable
public final class QuotaStore {
    public private(set) var results: [ProviderResult] = []
    public private(set) var lastRefreshAt: Date?
    public private(set) var isRefreshing = false

    /// 快照有变化并写入小组件容器后的回调。应用层用它触发 WidgetCenter 重画。
    /// 放在回调里而不是在核心里 import WidgetKit，保持核心不依赖 UI 框架。
    public var onWidgetDataChanged: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var pollTasks: [ProviderID: Task<Void, Never>] = [:]
    private var lastPublished: [WidgetSnapshot] = []

    public init(settings: AppSettings) {
        self.settings = settings
        self.results = settings.activeProviders.map {
            ProviderResult(id: $0.metadata.id, metadata: $0.metadata, isLoading: false)
        }
    }

    /// 与当前启用列表对齐结果数组，保留已有数据避免刷新时闪烁。
    public func syncWithSettings() {
        let providers = settings.activeProviders
        var next: [ProviderResult] = []
        for provider in providers {
            if let existing = results.first(where: { $0.id == provider.metadata.id }) {
                next.append(existing)
            } else {
                next.append(ProviderResult(
                    id: provider.metadata.id,
                    metadata: provider.metadata,
                    isLoading: true))
            }
        }
        results = next
    }

    // MARK: - 拉取

    public func refreshAll() async {
        syncWithSettings()
        guard !results.isEmpty else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshAt = Date()
        }

        let providers = settings.activeProviders
        let updates = await withTaskGroup(of: (ProviderID, QuotaSnapshot?, QuotaError?).self) { group in
            for provider in providers {
                group.addTask {
                    await self.fetchOne(provider)
                }
            }
            var collected: [(ProviderID, QuotaSnapshot?, QuotaError?)] = []
            for await update in group {
                collected.append(update)
            }
            return collected
        }

        apply(updates)
    }

    /// 只刷一个源。轮询循环用这个，避免每次都为所有源发请求。
    public func refresh(_ providerID: ProviderID) async {
        guard let provider = settings.activeProviders.first(where: { $0.id == providerID })
        else { return }
        let update = await fetchOne(provider)
        apply([update])
    }

    private func fetchOne(
        _ provider: ProviderDescriptor
    ) async -> (ProviderID, QuotaSnapshot?, QuotaError?) {
        let id = provider.metadata.id
        let credential = CredentialStore.loadCredential(for: id)
        guard credential.isComplete(for: provider.credentialFields) else {
            let names = provider.credentialFields
                .filter { !$0.isOptional && credential[$0.id] == nil }
                .map(\.title)
                .joined(separator: "、")
            return (id, nil, .missingCredential(names))
        }
        do {
            let snapshot = try await provider.fetchSnapshot(credential: credential)
            return (id, snapshot, nil)
        } catch let error as QuotaError {
            return (id, nil, error)
        } catch {
            return (id, nil, .network(error.localizedDescription))
        }
    }

    private func apply(_ updates: [(ProviderID, QuotaSnapshot?, QuotaError?)]) {
        let byID = Dictionary(uniqueKeysWithValues: updates.map { ($0.0, $0) })
        results = results.map { result in
            guard let (_, snapshot, error) = byID[result.id] else {
                return result
            }
            var updated = result
            updated.isLoading = false
            updated.error = error
            if let snapshot {
                updated.snapshot = snapshot
                updated.lastSuccessAt = snapshot.updatedAt
            }
            return updated
        }
        lastRefreshAt = Date()
        publishToWidget()
    }

    /// 把最新快照写进共享容器，供小组件渲染。
    ///
    /// 只在数据真的变化时写盘并回调：DeepSeek 每 5 秒轮询一次，
    /// 如果每次都通知 WidgetCenter 重画，会白白消耗系统的小组件刷新预算。
    private func publishToWidget() {
        let snapshots = results.compactMap { result -> WidgetSnapshot? in
            guard let snapshot = result.snapshot else { return nil }
            return snapshot.widgetSnapshot(
                id: result.id,
                vendor: result.metadata.vendor)
        }
        guard snapshots != lastPublished else { return }
        lastPublished = snapshots
        SharedStore.save(snapshots)
        onWidgetDataChanged?()
    }

    // MARK: - 轮询

    /// 为每个已启用的源起一个轮询循环。启用列表变化后需要重开。
    public func startLiveRefresh() {
        stopLiveRefresh()
        for provider in settings.activeProviders {
            let id = provider.id
            let interval = provider.refreshInterval
            pollTasks[id] = Task { [weak self] in
                // 先立刻刷一次，之后按各自节奏轮询。
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh(id)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
    }

    public func stopLiveRefresh() {
        for task in pollTasks.values {
            task.cancel()
        }
        pollTasks.removeAll()
    }

    public func restartLiveRefresh() {
        syncWithSettings()
        startLiveRefresh()
    }
}