import Foundation
import Observation

/// 应用设置。凭据不在这里，见 `CredentialStore`。
///
/// 刷新节奏不在这里配置：每个 Provider 自带 `refreshInterval`
/// （DeepSeek 余额接口轻，5 秒一轮做到近似实时；千问走控制台网关，保守一些），
/// 再叠加「回到前台 / 系统唤醒立即刷」的事件触发。全局间隔设置反而会让两边都对不上。
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

        let storedIDs = defaults.stringArray(forKey: Key.enabledProviders) ?? []
        self.enabledProviderIDs = storedIDs.map(ProviderID.init(rawValue:))
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
    }
}