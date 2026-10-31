import Foundation

/// 抓取器。主应用和小组件都用它，小组件因此**不依赖主应用运行**就能拿到新数据
/// （天气小组件就是这个模式：由系统调度唤醒扩展自己去请求）。
public enum QuotaFetcher {
    /// 用共享容器里的凭据抓一个来源。
    public static func fetch(_ provider: ProviderDescriptor) async -> (QuotaSnapshot?, QuotaError?) {
        let credential = CredentialStore.loadCredential(for: provider.id)
            .resolvingDefaults(for: provider.credentialFields)
        guard credential.isComplete(for: provider.credentialFields) else {
            let names = missingCredentialNames(
                for: provider.credentialFields,
                credential: credential)
                .joined(separator: "、")
            return (nil, .missingCredential(names))
        }
        do {
            let snapshot = try await provider.fetchSnapshot(credential: credential)
            return (snapshot, nil)
        } catch let error as QuotaError {
            return (nil, error)
        } catch {
            return (nil, .network(error.localizedDescription))
        }
    }

    /// 去重后的缺失必填字段名，用于「请先在设置中填写…」提示。
    static func missingCredentialNames(
        for fields: [CredentialField],
        credential: ProviderCredential
    ) -> [String] {
        fields
            .filter { !$0.isOptional && credential[$0.id] == nil && $0.defaultValue == nil }
            .map(\.title)
    }

    /// 抓所有**已配置凭据**的来源，直接产出小组件快照。
    public static func fetchAllWidgetSnapshots() async -> [WidgetSnapshot] {
        await fetchWidgetSnapshots(ids: nil)
    }

    /// 小组件抓取来源的过滤策略：共享启用列表 + 凭据完整 + 当前勾选的 ids。
    ///
    /// 纯函数，便于单测；共享启用列表为 nil 时退回旧版本的「只看凭据」。
    static func selectWidgetProviders(
        ids: Set<String>?,
        enabled: Set<String>?,
        configured: Set<String>
    ) -> [ProviderDescriptor] {
        ProviderRegistry.all.filter { provider in
            (enabled?.contains(provider.id.rawValue) ?? true)
                && configured.contains(provider.id.rawValue)
                && (ids == nil || ids!.contains(provider.id.rawValue))
        }
    }

    /// 抓小组件快照。`ids` 非空时只抓这些来源（未显示的供应商刷新时应忽略）。
    ///
    /// 同时看「共享启用列表」和「容器里有没有凭据」：主应用把启用列表写到共享目录，
    /// 小组件据此判断哪些来源仍可用。共享列表不存在（旧版本）时退回只看凭据。
    public static func fetchWidgetSnapshots(ids: Set<String>?) async -> [WidgetSnapshot] {
        let enabled = SharedStore.loadEnabledProviderIDs().map(Set.init)
        let configured = Set(ProviderRegistry.all
            .filter { CredentialStore.loadCredential(for: $0.id).isComplete(for: $0.credentialFields) }
            .map(\.id.rawValue))
        let providers = selectWidgetProviders(ids: ids, enabled: enabled, configured: configured)
        guard !providers.isEmpty else { return [] }

        let fetched = await withTaskGroup(of: WidgetSnapshot?.self) { group in
            for provider in providers {
                group.addTask {
                    let (snapshot, _) = await fetch(provider)
                    guard let snapshot else { return nil }
                    return snapshot.widgetSnapshot(
                        id: provider.id,
                        vendor: provider.metadata.vendor,
                        title: provider.metadata.displayName)
                }
            }
            var results: [WidgetSnapshot] = []
            for await item in group where item != nil {
                results.append(item!)
            }
            return results
        }

        // 保持 ProviderRegistry 的稳定顺序，避免每次刷新顺序跳动。
        return providers.compactMap { provider in
            fetched.first { $0.id == provider.id.rawValue }
        }
    }
}