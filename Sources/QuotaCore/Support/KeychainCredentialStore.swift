import Foundation
import Security

/// 凭据存储。
///
/// Cookie / API Key 等价于登录态，不能明文落在 `UserDefaults` 或配置文件里，
/// 统一存进 Keychain，并把访问权限限定为本机、解锁后可读、不参与 iCloud 同步与备份迁移。
public enum KeychainCredentialStore {
    private static let service = "com.skysh3n.ModelQuotaBar.credentials"

    private static func account(for providerID: ProviderID) -> String {
        providerID.rawValue
    }

    public static func loadCredential(for providerID: ProviderID) -> ProviderCredential {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return ProviderCredential()
        }
        return ProviderCredential(values)
    }

    public static func save(_ credential: ProviderCredential, for providerID: ProviderID) throws {
        let data = try JSONEncoder().encode(credential.allValues)
        var query = baseQuery(for: providerID)

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public static func delete(for providerID: ProviderID) {
        SecItemDelete(baseQuery(for: providerID) as CFDictionary)
    }

    private static func baseQuery(for providerID: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerID),
        ]
    }

    public enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "无法写入钥匙串（\(status)）：\(message)"
            }
        }
    }
}