import Foundation

/// 各来源共用的浏览器标识。控制台接口会拒绝明显不像浏览器的 UA。
enum BrowserIdentity {
    static let safariOnMac =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"
}

/// 把用户粘贴的裸值补成 `name=value`。已经带这个键名时原样返回。
enum CookieHeader {
    static func withName(_ name: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\(name)=") { return trimmed }
        return "\(name)=\(trimmed)"
    }
}

/// 各来源共用的 HTTP 骨架：发请求、按状态码分类、把正文解成 JSON。
///
/// 各厂商的请求头仍然自己拼。这里只收「发出去之后怎么判错」，避免四套几乎一样的样板。
enum ProviderHTTP {
    /// 401/403 时怎么报。密钥被拒和 Cookie 会话过期不是一回事。
    enum AuthFailure: Sendable {
        case sessionExpired
        case invalidCredential(String)
    }

    static func send(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
    }

    static func validate(
        _ response: HTTPURLResponse?,
        authFailure: AuthFailure
    ) throws {
        guard let http = response else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            switch authFailure {
            case .sessionExpired:
                throw QuotaError.sessionExpired
            case let .invalidCredential(reason):
                throw QuotaError.invalidCredential(reason)
            }
        default:
            throw QuotaError.network("HTTP \(http.statusCode)")
        }
    }

    /// 把正文解成 JSON。`sessionHTMLMarkers` 非空时，不像 JSON 且命中标记就当成登录页。
    static func jsonObject(
        from data: Data,
        sessionHTMLMarkers: [String] = []
    ) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            if !sessionHTMLMarkers.isEmpty {
                let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                if sessionHTMLMarkers.contains(where: { text.contains($0) }) {
                    throw QuotaError.sessionExpired
                }
            }
            throw QuotaError.decoding("响应不是合法 JSON")
        }
    }
}
