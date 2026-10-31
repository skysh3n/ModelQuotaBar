import Foundation

/// 凭据存储。
///
/// **为什么不用钥匙串。** 凭据（控制台会话 Cookie）等价于登录态，直觉上应该放钥匙串。
/// 但钥匙串是按**代码签名**识别调用方的：本项目由使用者各自本地构建、各用自己的证书签名，
/// 每次重新编译签名都会变，macOS 就把程序当成另一个应用，每次启动都弹一次系统密码框。
/// 那个交互没法接受，所以改用文件。
///
/// **为什么放在共享容器而不是 Application Support。** 小组件要能**自己**抓数据
/// （像天气小组件那样，不依赖主应用运行），就必须读得到凭据。共享容器正是主应用与
/// 小组件都能访问的位置，于是凭据放这里，两边共用同一份。
public enum CredentialStore {
    private static let fileName = "credentials.json"

    private static var fileURL: URL? {
        SharedStore.containerURL?.appendingPathComponent(fileName)
    }

    /// 旧版本把凭据存在 Application Support 里，迁移过来，免得用户重填。
    private static var legacyFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        else { return nil }
        return base
            .appendingPathComponent("ModelQuotaBar", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 所有 Provider 的凭据，按 ProviderID 索引。带 URL 参数是为了单测，生产路径用上面的默认值。
    static func loadAll(from fileURL: URL?, legacyURL: URL?) -> [String: [String: String]] {
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        {
            return decoded
        }
        // 共享容器里还没有（或读不出来），看看旧位置有没有，有就搬过来。
        guard let legacyURL,
              let data = try? Data(contentsOf: legacyURL),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        // 只有新位置写成功才删旧文件，避免共享目录不可写时永久丢凭据。
        do {
            try persist(decoded, to: fileURL)
            try? FileManager.default.removeItem(at: legacyURL)
        } catch {
            // 本进程仍可用内存里这份；下次启动还会再尝试迁移。
        }
        return decoded
    }

    static func persist(_ all: [String: [String: String]], to fileURL: URL?) throws {
        guard let fileURL else {
            throw CredentialError.storageUnavailable
        }
        let data = try JSONEncoder().encode(all)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        // 只留属主读写。原子写入会重建文件，权限位要在写完后再设一次。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    public static func loadCredential(for providerID: ProviderID) -> ProviderCredential {
        loadCredential(for: providerID, from: fileURL, legacyURL: legacyFileURL)
    }

    static func loadCredential(
        for providerID: ProviderID,
        from fileURL: URL?,
        legacyURL: URL?
    ) -> ProviderCredential {
        ProviderCredential(loadAll(from: fileURL, legacyURL: legacyURL)[providerID.rawValue] ?? [:])
    }

    public static func save(_ credential: ProviderCredential, for providerID: ProviderID) throws {
        try save(credential, for: providerID, to: fileURL, legacyURL: legacyFileURL)
    }

    static func save(
        _ credential: ProviderCredential,
        for providerID: ProviderID,
        to fileURL: URL?,
        legacyURL: URL?
    ) throws {
        var all = loadAll(from: fileURL, legacyURL: legacyURL)
        let values = credential.allValues
        if values.isEmpty {
            all.removeValue(forKey: providerID.rawValue)
        } else {
            all[providerID.rawValue] = values
        }
        try persist(all, to: fileURL)
    }

    public static func delete(for providerID: ProviderID) {
        delete(for: providerID, from: fileURL, legacyURL: legacyFileURL)
    }

    static func delete(for providerID: ProviderID, from fileURL: URL?, legacyURL: URL?) {
        var all = loadAll(from: fileURL, legacyURL: legacyURL)
        all.removeValue(forKey: providerID.rawValue)
        try? persist(all, to: fileURL)
    }

    public enum CredentialError: LocalizedError {
        case storageUnavailable

        public var errorDescription: String? {
            "找不到可写的应用数据目录，无法保存凭据。"
        }
    }
}
