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

    /// 用过「登录获取」（内嵌网页登录）的来源。
    ///
    /// 只有这些来源才有可续期的网页登录态，后台保活才有意义；手动粘贴 Cookie 的
    /// 情况没有登录态可用，保活只会白开一个网页。
    public var webLoginProviderIDs: [ProviderID] {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let enabledProviders = "enabledProviderIDs"
        static let webLoginProviders = "webLoginProviderIDs"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedIDs = defaults.stringArray(forKey: Key.enabledProviders) ?? []
        self.enabledProviderIDs = storedIDs.map(ProviderID.init(rawValue:))

        let webIDs = defaults.stringArray(forKey: Key.webLoginProviders) ?? []
        self.webLoginProviderIDs = webIDs.map(ProviderID.init(rawValue:))
    }

    public func markWebLoginUsed(_ id: ProviderID) {
        guard !webLoginProviderIDs.contains(id) else { return }
        webLoginProviderIDs.append(id)
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
        defaults.set(webLoginProviderIDs.map(\.rawValue), forKey: Key.webLoginProviders)
    }
}