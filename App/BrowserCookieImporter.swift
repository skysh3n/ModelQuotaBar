import CommonCrypto
import Foundation
import SQLite3
import Security

/// 从浏览器里读登录凭据（Cookie）。
///
/// 为什么要走这条路：macOS 的密码自动填充是 Safari 的功能，自己的 App 想用系统密码管理
/// 需要受限权限（要 provisioning profile），而本项目刻意不依赖它。让用户在**自己常用的
/// 浏览器**里登录、App 直接读它的登录态，就等于借用了浏览器已经记住的账号密码。
///
/// 代价是两处都要碰非公开机制，因此每一步失败都尽量给出可读的原因：
/// - Safari：读 `Cookies.binarycookies`（二进制格式），需要「完全磁盘访问」权限。
/// - Chrome：从钥匙串取 "Chrome Safe Storage" 密钥解密 Cookie 库（SQLite），会弹一次授权。
enum BrowserCookieImporter {
    enum Browser: String {
        case safari = "Safari"
        case chrome = "Chrome"
    }

    struct Imported {
        let value: String
        let browser: Browser
    }

    enum ImportError: LocalizedError {
        case notFound(Browser, String)
        case permissionDenied(Browser)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .notFound(browser, detail):
                "\(browser.rawValue)：\(detail)"
            case let .permissionDenied(browser):
                "\(browser.rawValue)：读不到数据，可能缺少系统权限。"
            case let .unsupported(detail):
                detail
            }
        }
    }

    /// 按 Safari → Chrome 的顺序找。返回第一个读到的值，以及各自失败的原因。
    static func findCookie(named name: String) -> (imported: Imported?, failures: [String]) {
        var failures: [String] = []
        for browser in [Browser.safari, .chrome] {
            do {
                if let value = try cookie(named: name, from: browser) {
                    return (Imported(value: value, browser: browser), failures)
                }
                failures.append("\(browser.rawValue)：已登录的站点里没有找到该凭据，先在 \(browser.rawValue) 里登录一次百炼控制台。")
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return (nil, failures)
    }

    private static func cookie(named name: String, from browser: Browser) throws -> String? {
        switch browser {
        case .safari: try safariCookie(named: name)
        case .chrome: try chromeCookie(named: name)
        }
    }

    // MARK: - Safari

    private static func safariCookie(named name: String) throws -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ImportError.notFound(.safari, "找不到 Cookie 文件，Safari 可能还没被用过。")
        }
        guard let data = try? Data(contentsOf: url) else {
            // 文件存在但读不了，几乎都是没给「完全磁盘访问权限」。
            throw ImportError.permissionDenied(.safari)
        }
        return try BinaryCookies.parse(data).first { $0.name == name }?.value
    }

    // MARK: - Chrome

    private static func chromeCookie(named name: String) throws -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            throw ImportError.notFound(.chrome, "找不到 Chrome 的配置目录，可能没装或没运行过。")
        }

        var databases: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "Cookies" {
            databases.append(url)
        }
        guard !databases.isEmpty else {
            throw ImportError.notFound(.chrome, "没有找到 Cookie 数据库。")
        }

        let key = try chromeDecryptionKey()

        for database in databases {
            for (encrypted, prefix) in try chromeEncryptedValues(at: database, name: name) {
                if let value = chromeDecrypt(encrypted, prefix: prefix, key: key) {
                    return value
                }
            }
        }
        return nil
    }

    /// 从钥匙串取 Chrome 的加密密钥原材料。这一步会让 macOS 弹一次授权框。
    private static func chromeDecryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw ImportError.permissionDenied(.chrome)
            }
            throw ImportError.notFound(.chrome, "取不到钥匙串里的解密密钥（状态 \(status)）。")
        }
        // Chrome 用 PBKDF2-SHA1 从这段口令派生 AES-128 密钥。
        return try pbkdf2(password: password, salt: Data("saltysalt".utf8), rounds: 1003, length: 16)
    }

    private static func pbkdf2(password: Data, salt: Data, rounds: UInt32, length: Int) throws -> Data {
        var derived = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    rounds,
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else {
            throw ImportError.unsupported("派生解密密钥失败（状态 \(status)）。")
        }
        return Data(derived)
    }

    private static func chromeEncryptedValues(
        at database: URL,
        name: String
    ) throws -> [(Data, String)] {
        var handle: OpaquePointer?
        // 只读打开，且不介意 Chrome 正开着（WAL 允许并发读）。
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ImportError.notFound(.chrome, "打不开 Cookie 数据库。")
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT encrypted_value FROM cookies WHERE name = ? AND host_key LIKE '%aliyun%';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.notFound(.chrome, "Cookie 数据库结构不认识。")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, name, -1, nil)

        var results: [(Data, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: blob, count: count)
            // 前 3 字节是版本前缀，目前见过 "v10"（钥匙串密钥）和 "v20"（应用绑定加密）。
            let prefix = String(decoding: data.prefix(3), as: UTF8.self)
            results.append((Data(data.dropFirst(3)), prefix))
        }
        return results
    }

    private static func chromeDecrypt(_ ciphertext: Data, prefix: String, key: Data) -> String? {
        guard prefix == "v10" else {
            // v20 是 Chrome 较新的「应用绑定加密」，密钥不再从钥匙串直接取，这里解不了。
            return nil
        }
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        // Chrome 用的是固定的 16 个空格作为 IV。
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                ciphertext.withUnsafeBytes { dataBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                        keyBuffer.baseAddress, key.count,
                        ivBuffer.baseAddress,
                        dataBuffer.baseAddress, ciphertext.count,
                        &output, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plaintext = Data(output.prefix(moved))
        // 去掉 PKCS7 填充。
        if let last = plaintext.last {
            let padding = Int(last)
            if padding > 0, padding <= kCCBlockSizeAES128, padding <= plaintext.count {
                plaintext = plaintext.dropLast(padding)
            }
        }
        let value = String(data: plaintext, encoding: .utf8)
        return (value?.isEmpty == false) ? value : nil
    }
}

// MARK: - Safari 的二进制 Cookie 格式

/// Safari 的 `Cookies.binarycookies` 解析。
///
/// 格式（均为大端）：
/// - 文件头：`cookies` 魔数 + 页数
/// - 页：页起始、页长度、Cookie 数、各 Cookie 的偏移
/// - Cookie：长度、标志、URL/名称/路径/值 的字符串偏移、过期时间、创建时间，随后是各字符串
private enum BinaryCookies {
    struct Cookie {
        let name: String
        let value: String
    }

    static func parse(_ data: Data) throws -> [Cookie] {
        guard data.count > 8, data.prefix(4) == Data("cook".utf8) else {
            throw BrowserCookieImporter.ImportError.unsupported("Safari 的 Cookie 文件格式不认识。")
        }

        var cookies: [Cookie] = []
        let pageCount = Int(readUInt32(data, at: 4))
        var pageStart = 8

        for _ in 0..<pageCount {
            guard pageStart + 8 <= data.count else { break }
            let pageSize = Int(readUInt32(data, at: pageStart + 4))
            let cookieCount = Int(readUInt32(data, at: pageStart + 8))
            var offsetCursor = pageStart + 12

            for _ in 0..<cookieCount {
                let cookieOffset = Int(readUInt32(data, at: offsetCursor))
                offsetCursor += 4
                if let cookie = parseCookie(data, at: pageStart + cookieOffset) {
                    cookies.append(cookie)
                }
            }
            pageStart += pageSize
        }
        return cookies
    }

    private static func parseCookie(_ data: Data, at start: Int) -> Cookie? {
        // 各字符串相对 Cookie 起始位置的偏移量分别落在固定的 4 字节槽里。
        guard start + 56 <= data.count else { return nil }
        let nameOffset = Int(readUInt32(data, at: start + 20))
        let valueOffset = Int(readUInt32(data, at: start + 28))
        guard let name = string(data, from: start + nameOffset),
              let value = string(data, from: start + valueOffset)
        else { return nil }
        return Cookie(name: name, value: value)
    }

    private static func string(_ data: Data, from offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 { end += 1 }
        guard end > offset else { return nil }
        return String(data: data[offset..<end], encoding: .utf8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
