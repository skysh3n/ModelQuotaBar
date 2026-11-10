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
/// 刷新没有定时轮询：启动时用本地缓存先出界面（没有任何缓存才补拉一次），
/// 之后靠手动刷新；小组件自己抓数据，由系统调度。
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
    /// 重叠刷新时只采纳最新一轮，避免旧结果盖掉新凭据后的数据。
    private var refreshGeneration = 0

    public init(settings: AppSettings) {
        self.settings = settings
        let cached = SnapshotCache.load(from: SnapshotCache.defaultURL)
        self.results = settings.activeProviders.map { provider in
            var result = ProviderResult(
                id: provider.metadata.id,
                metadata: provider.metadata,
                isLoading: false)
            if let snapshot = cached[provider.metadata.id.rawValue] {
                result.snapshot = snapshot
                result.lastSuccessAt = snapshot.updatedAt
            }
            return result
        }
        self.lastRefreshAt = self.results.compactMap(\.snapshot?.updatedAt).max()
    }

    /// 是否已有可展示的缓存。启动时据此决定要不要补一次网络请求。
    public var hasCachedData: Bool {
        results.contains { $0.snapshot != nil }
    }

    /// 启用列表变化后立刻按「仍启用」重写小组件缓存。
    ///
    /// 不能等这一轮网络刷新结束：否则桌面上的小组件会继续显示刚关掉的来源。
    public func alignWidgetWithSettings() {
        syncWithSettings()
        publishToWidget()
    }

    /// 与当前启用列表对齐结果数组，保留已有数据避免刷新时闪烁；
    /// 新启用的来源先拿本地缓存顶上。
    public func syncWithSettings() {
        let providers = settings.activeProviders
        let cached = SnapshotCache.load(from: SnapshotCache.defaultURL)
        var next: [ProviderResult] = []
        for provider in providers {
            if let existing = results.first(where: { $0.id == provider.metadata.id }) {
                next.append(existing)
            } else {
                var result = ProviderResult(
                    id: provider.metadata.id,
                    metadata: provider.metadata,
                    isLoading: false)
                if let snapshot = cached[provider.metadata.id.rawValue] {
                    result.snapshot = snapshot
                    result.lastSuccessAt = snapshot.updatedAt
                }
                next.append(result)
            }
        }
        results = next
    }

    /// 拉取所有已启用的来源。事件触发和手动刷新都走这里。
    public func refreshAll() async {
        syncWithSettings()
        // 全部关掉时也要走到 publish，才能清空小组件缓存。
        guard !results.isEmpty else {
            publishToWidget()
            saveCache()
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        results = results.map { result in
            var loading = result
            loading.isLoading = true
            return loading
        }
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
                lastRefreshAt = Date()
            }
        }

        let providers = settings.activeProviders
        let updates = await withTaskGroup(of: (ProviderID, QuotaSnapshot?, QuotaError?).self) { group in
            for provider in providers {
                group.addTask {
                    let (snapshot, error) = await QuotaFetcher.fetch(provider)
                    return (provider.id, snapshot, error)
                }
            }
            var collected: [(ProviderID, QuotaSnapshot?, QuotaError?)] = []
            for await update in group {
                collected.append(update)
            }
            return collected
        }

        guard generation == refreshGeneration else { return }
        apply(updates)
    }

    private func apply(_ updates: [(ProviderID, QuotaSnapshot?, QuotaError?)]) {
        // 不用 Dictionary(uniqueKeysWithValues:)：启用列表若有重复 id（旧版
        // defaults 或手改）会直接 trap。
        var byID: [ProviderID: (ProviderID, QuotaSnapshot?, QuotaError?)] = [:]
        for update in updates {
            byID[update.0] = update
        }
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
        saveCache()
        publishToWidget()
    }

    /// 把完整快照写进主应用自己的缓存，下次启动先拿它出界面。
    private func saveCache() {
        var cached: [String: QuotaSnapshot] = [:]
        for result in results {
            guard let snapshot = result.snapshot else { continue }
            cached[result.id.rawValue] = snapshot
        }
        SnapshotCache.save(cached, to: SnapshotCache.defaultURL)
    }

    /// 小组件缓存发布策略：只保留仍启用且凭据完整的来源；抓取失败但凭据还在的
    /// 保留上一次成功数据；停用/清空凭据的来源从缓存里消失。
    ///
    /// 纯函数，便于单测。
    nonisolated static func widgetSnapshotsForPublish(
        disk: [WidgetSnapshot],
        fresh: [WidgetSnapshot],
        configuredIDs: Set<String>
    ) -> [WidgetSnapshot] {
        let cached = disk.filter { configuredIDs.contains($0.id) }
        let freshConfigured = fresh.filter { configuredIDs.contains($0.id) }
        return SharedStore.mergeSnapshots(cached: cached, fresh: freshConfigured)
    }

    /// 把最新快照写进共享容器，供小组件渲染。
    ///
    /// 只保留「仍启用且凭据完整」的来源：停用来源、清空凭据后不再留下旧快照；
    /// 抓取失败但凭据还在的保留上一次成功数据，避免小组件被洗成空状态。
    /// 内容真的变化时才重载小组件；只有时间戳变化时仍写盘（供缓存时效判断）。
    ///
    /// 凭据文件读失败时（loadFailed）：跳过写盘，保留 disk 原样，不触发 onWidgetDataChanged。
    /// 这样小组件继续显示旧数据，而不是被洗成空状态。
    func publishToWidget() {
        publishToWidget(
            credentialFileURL: nil,
            legacyCredentialFileURL: nil,
            sharedStoreFileURL: nil)
    }

    /// 内部变体：允许注入凭据文件路径和共享存储路径，供测试使用。
    /// nil 表示使用默认路径（生产路径），非 nil 表示使用注入路径（测试路径）。
    func publishToWidget(
        credentialFileURL: URL?,
        legacyCredentialFileURL: URL?,
        sharedStoreFileURL: URL?
    ) {
        // nil 时使用默认路径，非 nil 时使用注入路径
        let disk: [WidgetSnapshot]
        if let url = sharedStoreFileURL {
            disk = SharedStore.loadSnapshots(from: url)
        } else {
            disk = SharedStore.loadSnapshots()
        }

        let activeIDs = Set(settings.activeProviders.map(\.id.rawValue))

        // 逐个来源检查凭据，区分「读失败」和「真的没凭据」
        var configuredIDs: Set<String> = []
        var anyLoadFailed = false
        for provider in ProviderRegistry.all where activeIDs.contains(provider.id.rawValue) {
            let (credential, loadFailed): (ProviderCredential, Bool)
            if let credURL = credentialFileURL {
                // 注入路径：使用指定的凭据文件
                (credential, loadFailed) = CredentialStore.loadCredentialWithStatus(
                    for: provider.id,
                    from: credURL,
                    legacyURL: legacyCredentialFileURL)
            } else {
                // 默认路径：使用 CredentialStore 的默认文件位置
                (credential, loadFailed) = CredentialStore.loadCredentialWithStatus(for: provider.id)
            }

            if loadFailed {
                anyLoadFailed = true
                // 读失败时保守保留该来源（不加入 configuredIDs，但也不主动丢弃）
            } else if credential.isComplete(for: provider.credentialFields) {
                configuredIDs.insert(provider.id.rawValue)
            }
        }

        // 凭据读失败且 disk 非空时：跳过写盘，保留旧数据，不触发刷新
        if anyLoadFailed && !disk.isEmpty {
            return
        }

        let fresh = results.compactMap { result -> WidgetSnapshot? in
            guard let snapshot = result.snapshot else { return nil }
            return snapshot.widgetSnapshot(
                id: result.id,
                vendor: result.metadata.vendor,
                title: result.metadata.displayName)
        }
        let merged = Self.widgetSnapshotsForPublish(
            disk: disk,
            fresh: fresh,
            configuredIDs: configuredIDs)

        let contentChanged = !SharedStore.snapshotsHaveSameContent(merged, disk)
        if merged != disk {
            if let url = sharedStoreFileURL {
                SharedStore.save(merged, to: url)
            } else {
                SharedStore.save(merged)
            }
        }
        if contentChanged {
            onWidgetDataChanged?()
        }
    }
}

/// 主应用自己的完整额度缓存，用于启动时先显示上次结果。
///
/// 放在应用自己的 Application Support（不是小组件容器）：小组件只需要精简快照，
/// 这里保留 `QuotaSnapshot` 全量字段，供主界面的卡片恢复 status、到期时间、所有窗口。
enum SnapshotCache {
    private static let fileName = "quota-cache.json"

    static var defaultURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        else { return nil }
        let directory = base.appendingPathComponent("ModelQuotaBar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }

    static func load(from url: URL?) -> [String: QuotaSnapshot] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: QuotaSnapshot].self, from: data)) ?? [:]
    }

    static func save(_ snapshots: [String: QuotaSnapshot], to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
