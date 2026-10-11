import Foundation
import Observation

/// 应用设置。凭据不在这里，见 `CredentialStore`。
@MainActor
@Observable
public final class AppSettings {
    public var enabledProviderIDs: [ProviderID] {
        didSet { persist() }
    }

    /// 自动刷新间隔（秒）。0 表示不自动刷新。
    public var refreshInterval: TimeInterval {
        didSet { persist() }
    }

    public static let refreshIntervalOptions: [TimeInterval] = [60, 300, 900, 1800, 3600, 0]

    private let defaults: UserDefaults

    private enum Key {
        static let enabledProviders = "enabledProviderIDs"
        static let refreshInterval = "refreshInterval"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedIDs = defaults.stringArray(forKey: Key.enabledProviders) ?? []
        self.enabledProviderIDs = storedIDs.map(ProviderID.init(rawValue:))

        let storedInterval = defaults.object(forKey: Key.refreshInterval) as? TimeInterval
        // 默认 15 分钟：足够跟上额度变化，也不会频繁打扰百炼控制台网关。
        self.refreshInterval = storedInterval ?? 900
    }

    /// 已启用的 Provider。
    public var activeProviders: [ProviderDescriptor] {
        enabledProviderIDs.compactMap(ProviderRegistry.descriptor(for:))
    }

    public func isEnabled(_ id: ProviderID) -> Bool {
        enabledProviderIDs.contains(id)
    }

    public func setEnabled(_ enabled: Bool, for id: ProviderID) {
        if enabled {
            guard !enabledProviderIDs.contains(id) else { return }
            enabledProviderIDs.append(id)
        } else {
            enabledProviderIDs.removeAll { $0 == id }
            CredentialStore.delete(for: id)
        }
    }

    private func persist() {
        defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Key.enabledProviders)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
    }
}