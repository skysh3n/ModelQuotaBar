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
/// 刷新是**事件驱动**的，没有定时轮询：应用回到前台、切换空间/桌面、系统唤醒、
/// 解锁回到会话时立即刷一次，另外提供手动刷新。服务端没有推送能力，
/// 这种「有动静就刷」的模式既能保证切到桌面瞬间是最新的，又不会空闲时持续打接口。
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

    /// 拉取所有已启用的来源。事件触发和手动刷新都走这里。
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
    /// 只在数据真的变化时写盘并回调，避免无谓地消耗小组件刷新预算。
    private func publishToWidget() {
        let snapshots = results.compactMap { result -> WidgetSnapshot? in
            guard let snapshot = result.snapshot else { return nil }
            return snapshot.widgetSnapshot(
                id: result.id,
                vendor: result.metadata.vendor)
        }
        // 有启用的源、但这次全都拉取失败：保留上一次写进容器里的数据，
        // 别把小组件洗成「还没取到额度」。只有真正没有任何启用的源时才清空。
        if snapshots.isEmpty && !settings.activeProviders.isEmpty {
            return
        }
        guard snapshots != lastPublished else { return }
        lastPublished = snapshots
        SharedStore.save(snapshots)
        onWidgetDataChanged?()
    }
}