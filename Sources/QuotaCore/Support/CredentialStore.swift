import Foundation

/// 凭据存储。
///
/// **为什么不用钥匙串。** 凭据（控制台会话 Cookie）等价于登录态，直觉上应该放钥匙串。
/// 但钥匙串是按**代码签名**识别调用方的：本项目由使用者各自本地构建、各用自己的证书签名，
/// 每次重新编译签名都会变，macOS 就把程序当成另一个应用，每次启动都弹一次系统密码框。
/// 那个交互没法接受，所以改用文件。
///
/// 文件放在应用**自己的沙盒容器**里（`~/Library/Containers/<bundle id>/Data/...`）。
/// 沙盒保证其它应用读不到它，再把权限位收成 0600 只留属主可读写。
/// 安全性低于钥匙串——同一个用户账号下的进程仍可读——但对一个只用来看自己套餐余量的
/// 工具来说，这个折中是划算的，换来的是完全无感的配置体验。
public enum CredentialStore {
    private static let fileName = "credentials.json"

    private static var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        else { return nil }
        return directory.appendingPathComponent(fileName)
    }

    /// 所有 Provider 的凭据，按 ProviderID 索引。
    private static func loadAll() -> [String: [String: String]] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persist(_ all: [String: [String: String]]) throws {
        guard let url = fileURL else {
            throw CredentialError.storageUnavailable
        }
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        // 只留属主读写。原子写入会重建文件，权限位要在写完后再设一次。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }

    public static func loadCredential(for providerID: ProviderID) -> ProviderCredential {
        ProviderCredential(loadAll()[providerID.rawValue] ?? [:])
    }

    public static func save(_ credential: ProviderCredential, for providerID: ProviderID) throws {
        var all = loadAll()
        let values = credential.allValues
        if values.isEmpty {
            all.removeValue(forKey: providerID.rawValue)
        } else {
            all[providerID.rawValue] = values
        }
        try persist(all)
    }

    public static func delete(for providerID: ProviderID) {
        var all = loadAll()
        all.removeValue(forKey: providerID.rawValue)
        try? persist(all)
    }

    public enum CredentialError: LocalizedError {
        case storageUnavailable

        public var errorDescription: String? {
            "找不到可写的应用数据目录，无法保存凭据。"
        }
    }
}