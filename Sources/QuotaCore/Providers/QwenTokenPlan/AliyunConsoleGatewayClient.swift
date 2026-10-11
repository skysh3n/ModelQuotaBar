import Foundation

/// 阿里云 OneConsole 控制台网关客户端。
///
/// 百炼没有开放查询套餐用量的 OpenAPI，控制台页面自己走的是这套「网关 + Cookie」通道：
///
/// ```
/// POST {quotaHost}/data/api.json?action=<gatewayAction>&product=sfm_bailian&api=<api>&_v=undefined
/// Cookie: login_aliyunid_ticket=<ticket>
/// Body:   product=…&action=…&region=…&language=…&params=<JSON>
/// ```
///
/// 其中 `params` 是 `{Api, V, Data}` 三段式信封，`Data.cornerstoneParam` 携带控制台的
/// 埋点/租户上下文。网关只认 `login_aliyunid_ticket` 这一个 Cookie。
struct AliyunConsoleGatewayClient: Sendable {
    let region: QwenTokenPlanRegion
    let cookieHeader: String
    private let session: URLSession

    init(region: QwenTokenPlanRegion, cookieHeader: String, session: URLSession = .shared) {
        self.region = region
        self.cookieHeader = cookieHeader
        self.session = session
    }

    /// 调一次网关接口，返回解析后的 JSON 对象。
    func call(api: String) async throws -> Any {
        var urlString = region.quotaBaseURL + "/data/api.json?"
        urlString += FormEncoding.query([
            ("action", region.gatewayAction),
            ("product", Self.consoleProduct),
            ("api", api),
            ("_v", "undefined"),
        ])
        guard let url = URL(string: urlString) else {
            throw QuotaError.network("无法构造请求地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try Self.requestBody(api: api, region: region)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.normalizedCookie(cookieHeader), forHTTPHeaderField: "Cookie")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.consoleOrigin, forHTTPHeaderField: "Origin")
        request.setValue(region.consoleOrigin + "/", forHTTPHeaderField: "Referer")
        request.setValue(region.language, forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.sessionExpired
            }
            throw QuotaError.network("HTTP \(http.statusCode)")
        }

        guard !data.isEmpty else {
            throw QuotaError.decoding("服务端返回空响应")
        }
        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: data)
        } catch {
            // 会话过期时控制台网关会直接回登录页 HTML，而不是 JSON 错误体。
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("<html") || text.contains("login") || text.contains("signin") {
                throw QuotaError.sessionExpired
            }
            throw QuotaError.decoding("响应不是合法 JSON")
        }

        try Self.throwIfError(payload)
        return payload
    }

    // MARK: - 请求构造

    /// 控制台产品代号，与百炼控制台自身请求保持一致。
    private static let consoleProduct = "sfm_bailian"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    private static func requestBody(
        api: String,
        region: QwenTokenPlanRegion
    ) throws -> Data {
        // cornerstoneParam 里不要带 switchAgent：网关会把它绑到某个具体账号的
        // workspace，写死之后其他账号一律返回 BailianGateway.Workspace.NotAuthorised。
        // 留空才能让网关按会话解析默认 workspace。
        let cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": region.consoleURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "switchUserType": 3,
            "domain": region.consoleHost,
            "consoleSite": region.consoleSite,
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": region.language,
        ]
        let params: [String: Any] = [
            "Api": api,
            "V": "1.0",
            "Data": ["cornerstoneParam": cornerstone],
        ]
        let json = try JSONSerialization.data(withJSONObject: params)
        guard let jsonString = String(data: json, encoding: .utf8) else {
            throw QuotaError.decoding("无法编码请求参数")
        }

        return FormEncoding.body([
            ("product", consoleProduct),
            ("action", region.gatewayAction),
            ("region", region.regionID),
            ("language", region.language),
            ("params", jsonString),
        ])
    }

    /// 归一化用户粘贴的凭据。
    ///
    /// 控制台里复制的往往只是 ticket 的**值**，而它的值本身不含 `=`，
    /// 直接当作 Cookie 头发出去就没有 `name=value` 结构，网关一律判未登录——
    /// 表现得和「会话过期」一模一样，极易误判。这里自动补上键名。
    static func normalizedCookie(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("=") {
            return trimmed
        }
        return "login_aliyunid_ticket=\(trimmed)"
    }

    // MARK: - 错误判定

    /// 网关的业务失败是 `HTTP 200 + success=false`，不能用状态码判断，必须解析响应体。
    private static func throwIfError(_ payload: Any) throws {
        if let success = JSONSearch.findValue(forKeys: ["successResponse", "success_response"], in: payload),
           let flag = success as? Bool,
           flag == false
        {
            throw error(from: payload)
        }
        if containsFailedSuccessFrame(payload) {
            throw error(from: payload)
        }
    }

    private static func containsFailedSuccessFrame(_ payload: Any) -> Bool {
        if let dictionary = payload as? [String: Any] {
            if let success = dictionary["success"] as? Bool, success == false {
                return true
            }
            if let httpStatus = dictionary["httpStatus"] as? Int, httpStatus != 200 {
                return true
            }
            return dictionary.values.contains(where: containsFailedSuccessFrame)
        }
        if let array = payload as? [Any] {
            return array.contains(where: containsFailedSuccessFrame)
        }
        return false
    }

    private static func error(from payload: Any) -> QuotaError {
        let code = JSONSearch.string(
            JSONSearch.findValue(forKeys: ["errorCode", "Code", "code"], in: payload))
        let message = JSONSearch.string(
            JSONSearch.findValue(forKeys: ["errorMsg", "Message", "message", "msg"], in: payload))

        let haystack = [code, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if haystack.contains("notlogined") || haystack.contains("not_logined")
            || haystack.contains("login")
        {
            return .sessionExpired
        }
        if haystack.contains("notauthorised") || haystack.contains("not_authorised")
            || haystack.contains("forbidden") || haystack.contains("accessdenied")
        {
            return .invalidCredential(message ?? code ?? "当前账号无权访问该套餐")
        }
        return .api(message ?? code ?? "未知错误")
    }
}