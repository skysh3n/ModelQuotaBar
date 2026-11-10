import Foundation
import Observation

/// 应用设置。凭据不在这里，见 `CredentialStore`。
///
/// 刷新节奏也不在这里配置：主应用有缓存时只展示缓存，点「刷新」才请求；
/// 没有任何缓存时启动会补一次。见 `QuotaStore` / `AppEnvironment`。
@MainActor
@Observable
public final class AppSettings {
    public var enabledProviderIDs: [ProviderID] {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let enabledProviders = "enabledProviderIDs"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = defaults.stringArray(forKey: Key.enabledProviders)
        let shared = SharedStore.loadEnabledProviderIDs()
        let credentialed = ProviderRegistry.all
            .filter { CredentialStore.loadCredential(for: $0.id).isComplete(for: $0.credentialFields) }
            .map(\.id)
        self.enabledProviderIDs = Self.resolveInitialProviderIDs(
            stored: stored,
            shared: shared,
            credentialed: credentialed)
        // 初始化赋值不会触发 didSet，这里显式落盘一次，把共享列表补齐。
        persist()
    }

    /// 合并「共享目录里的启用列表」「UserDefaults 里的启用列表」「已有凭据的来源」。
    ///
    /// 共享列表是主应用和小组件都能读到的那一份，存在时以它为准。否则旧的
    /// UserDefaults 会在下次启动把已关闭的来源写回去，小组件又把通义千问显示出来。
    /// 共享列表不存在才是旧版本升级：用本地列表，并把已有凭据的来源并进来。
    /// 重复项和未知 id 一并清掉。
    nonisolated static func resolveInitialProviderIDs(
        stored: [String]?,
        shared: [String]?,
        credentialed: [ProviderID]
    ) -> [ProviderID] {
        let known = Set(ProviderRegistry.all.map(\.id))
        var seen = Set<ProviderID>()
        var result: [ProviderID] = []

        for raw in (shared ?? stored ?? []) {
            let id = ProviderID(rawValue: raw)
            guard known.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
        }

        if shared == nil {
            for id in credentialed where known.contains(id) && seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// 已启用的 Provider。
    public var activeProviders: [ProviderDescriptor] {
        enabledProviderIDs.compactMap(ProviderRegistry.descriptor(for:))
    }

    public func isEnabled(_ id: ProviderID) -> Bool {
        enabledProviderIDs.contains(id)
    }

    /// 开关只改「是否显示/抓取」，**不删凭据**。凭据删掉的话用户临时关一下
    /// 就得重新登录，代价太大；小组件现在通过共享的启用列表判断显不显示。
    public func setEnabled(_ enabled: Bool, for id: ProviderID) {
        if enabled {
            guard !enabledProviderIDs.contains(id) else { return }
            enabledProviderIDs.append(id)
        } else {
            enabledProviderIDs.removeAll { $0 == id }
        }
    }

    private func persist() {
        defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Key.enabledProviders)
        // 不强制刷到磁盘的话，cfprefsd 可能一直留着旧的启用列表，下次启动又把已关闭的来源写回去。
        defaults.synchronize()
        SharedStore.saveEnabledProviderIDs(enabledProviderIDs.map(\.rawValue))
    }
}
