import Foundation
import Observation

/// 应用设置。凭据不在这里，见 `CredentialStore`。
///
/// 刷新节奏也不在这里配置：额度是**事件驱动**刷新的（切桌面 / 唤醒 / 解锁 /
/// 回到前台），没有定时轮询。见 `QuotaStore`。
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