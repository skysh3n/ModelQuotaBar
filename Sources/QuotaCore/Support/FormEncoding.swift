import Foundation

/// `application/x-www-form-urlencoded` 请求体编码。
///
/// 不用 `URLComponents` 拼查询串：它按 RFC 3986 处理，而表单编码另有规则，
/// 且 `params` 里塞的是整段 JSON，含 `{` `"` `:` 等字符，必须逐字节转义。
enum FormEncoding {
    /// RFC 3986 unreserved 字符集，其余一律百分号转义。
    private static let unreserved: Set<Character> = {
        var set = Set<Character>()
        set.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.formUnion("abcdefghijklmnopqrstuvwxyz")
        set.formUnion("0123456789")
        set.formUnion("-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            let character = Character(UnicodeScalar(byte))
            if byte < 0x80, unreserved.contains(character) {
                output.append(character)
            } else {
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }

    /// 把键值对编码成表单请求体。空值按空串发送，不省略键。
    static func body(_ pairs: [(String, String)]) -> Data {
        let text = pairs
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
        return Data(text.utf8)
    }

    /// 把键值对拼成 URL 查询串。
    static func query(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }
}