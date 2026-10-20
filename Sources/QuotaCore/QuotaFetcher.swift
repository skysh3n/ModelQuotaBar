import Foundation

/// 抓取器。主应用和小组件都用它，小组件因此**不依赖主应用运行**就能拿到新数据
/// （天气小组件就是这个模式：由系统调度唤醒扩展自己去请求）。
public enum QuotaFetcher {
    /// 用共享容器里的凭据抓一个来源。
    public static func fetch(_ provider: ProviderDescriptor) async -> (QuotaSnapshot?, QuotaError?) {
        let credential = CredentialStore.loadCredential(for: provider.id)
        guard credential.isComplete(for: provider.credentialFields) else {
            let names = provider.credentialFields
                .filter { !$0.isOptional && credential[$0.id] == nil }
                .map(\.title)
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

    /// 抓所有**已配置凭据**的来源，直接产出小组件快照。
    public static func fetchAllWidgetSnapshots() async -> [WidgetSnapshot] {
        await fetchWidgetSnapshots(ids: nil)
    }

    /// 抓小组件快照。`ids` 非空时只抓这些来源（未显示的供应商刷新时应忽略）。
    ///
    /// 只看「容器里有没有凭据」，不看主应用的启用列表——小组件读不到主应用的
    /// UserDefaults，而凭据在用户禁用来源时会被删掉，两者天然一致。
    public static func fetchWidgetSnapshots(ids: Set<String>?) async -> [WidgetSnapshot] {
        let providers = ProviderRegistry.all.filter {
            CredentialStore.loadCredential(for: $0.id).isComplete(for: $0.credentialFields)
                && (ids == nil || ids!.contains($0.id.rawValue))
        }
        guard !providers.isEmpty else { return [] }

        let fetched = await withTaskGroup(of: WidgetSnapshot?.self) { group in
            for provider in providers {
                group.addTask {
                    let (snapshot, _) = await fetch(provider)
                    guard let snapshot else { return nil }
                    return snapshot.widgetSnapshot(id: provider.id, vendor: provider.metadata.vendor)
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