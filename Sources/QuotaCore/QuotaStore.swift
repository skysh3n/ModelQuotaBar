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

/// 额度查询的调度中心：负责拉取、缓存结果、驱动自动刷新。
@MainActor
@Observable
public final class QuotaStore {
    public private(set) var results: [ProviderResult] = []
    public private(set) var lastRefreshAt: Date?
    public private(set) var isRefreshing = false

    private let settings: AppSettings
    private var autoRefreshTask: Task<Void, Never>?

    public init(settings: AppSettings) {
        self.settings = settings
        self.results = settings.activeProviders.map {
            ProviderResult(id: $0.metadata.id, metadata: $0.metadata, isLoading: false)
        }
    }

    /// 主窗口剩余比例最低的那一项，用于菜单栏数字。
    public var menuBarResult: ProviderResult? {
        results.first { $0.snapshot?.primaryWindow != nil } ?? results.first
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

    public func refreshAll() async {
        syncWithSettings()
        guard !results.isEmpty else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshAt = Date()
        }

        let providers = settings.activeProviders
        let credentials = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.metadata.id, CredentialStore.loadCredential(for: $0.metadata.id))
        })

        let updates = await withTaskGroup(of: (ProviderID, QuotaSnapshot?, QuotaError?).self) { group in
            for provider in providers {
                let id = provider.metadata.id
                let credential = credentials[id] ?? ProviderCredential()
                let fields = provider.credentialFields

                group.addTask {
                    guard credential.isComplete(for: fields) else {
                        let names = fields
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
            }

            var collected: [(ProviderID, QuotaSnapshot?, QuotaError?)] = []
            for await update in group {
                collected.append(update)
            }
            return collected
        }

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

        publishToWidget()
    }

    /// 把最新快照写进共享容器，供小组件渲染。
    private func publishToWidget() {
        let snapshots = results.compactMap { result -> WidgetSnapshot? in
            guard let snapshot = result.snapshot else { return nil }
            return snapshot.widgetSnapshot(
                id: result.id,
                vendor: result.metadata.vendor)
        }
        SharedStore.save(snapshots)
    }

    public func startAutoRefresh() {
        stopAutoRefresh()
        guard settings.refreshInterval > 0 else { return }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = self.settings.refreshInterval
                guard seconds > 0 else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.refreshAll()
            }
        }
    }

    public func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}