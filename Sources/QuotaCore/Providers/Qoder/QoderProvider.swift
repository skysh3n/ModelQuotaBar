import Foundation

/// Qoder CN（全家桶）用量来源。
///
/// Qoder CN 没有公开查询个人用量的 REST API，用量页面（qoder.com.cn/account/usage）
/// 自身调用的内部接口如下：
///
/// - `GET /api/v1/me`：用户基本信息（昵称、邮箱）。
/// - `GET /api/v1/me/userplan`：当前订阅套餐（档位、计费周期、到期/刷新时间）。
/// - `GET /api/v2/me/usages/big_model_credits`：Credits 配额详情，
///   包含 plan_quota（套餐内月度配额）和 resource_package_quota（附加资源包）。
///
/// 鉴权走阿里云 SSO，但业务域名下的会话凭据是 `qoder_session_cookie`：
/// SSO 登录跳回 qoder.com.cn 时才下发，接口只认它。
public enum QoderProvider: QuotaProvider {
    public static let metadata = ProviderMetadata(
        id: ProviderID("qoder"),
        vendor: "Qoder CN",
        plan: "Credits 用量",
        summary: "查询 Qoder CN 当前订阅周期的 Credits 配额与附加资源包剩余。",
        consoleURL: URL(string: "https://qoder.com.cn/account/usage"),
        consoleHint:
            "两种获取方式任选其一：\n" +
            "①「登录获取」——在弹窗里登录一次即可，会话过期后再点一次重新获取；\n" +
            "② 手动——浏览器登录 qoder.com.cn，F12 → Application → Cookies → https://qoder.com.cn，" +
            "复制 qoder_session_cookie 的值。",
        webLogin: WebLoginSpec(
            url: URL(string: "https://qoder.com.cn/account/usage")!,
            postLoginURL: URL(string: "https://qoder.com.cn/account/usage")!,
            cookieName: "qoder_session_cookie",
            targetFieldID: "cookie",
            hint: "在弹出的窗口里登录 Qoder CN（阿里云账号）。登录成功后 App 会自动取到会话凭据。",
            validateCookie: { raw in await validateSession(cookie: raw) })
    )

    public static let credentialFields: [CredentialField] = [
        CredentialField(
            id: "cookie",
            title: "会话 Cookie",
            hint: "只需 qoder_session_cookie 的值。会话过期后重新登录获取即可。",
            kind: .secret
        ),
    ]

    private static let baseURL = "https://qoder.com.cn"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    public static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
        try await fetchSnapshot(credential: credential, session: .shared)
    }

    static func fetchSnapshot(
        credential: ProviderCredential,
        session: URLSession
    ) async throws -> QuotaSnapshot {
        guard let raw = credential["cookie"] else {
            throw QuotaError.missingCredential("会话 Cookie")
        }
        let cookie = normalizedCookie(raw)

        async let userPayload = try get(path: "/api/v1/me", cookie: cookie, session: session)
        async let planPayload = try get(path: "/api/v1/me/userplan", cookie: cookie, session: session)
        async let creditsPayload = try get(
            path: "/api/v2/me/usages/big_model_credits", cookie: cookie, session: session)

        let (user, plan, credits) = try await (userPayload, planPayload, creditsPayload)
        return try makeSnapshot(user: user, plan: plan, credits: credits)
    }

    // MARK: - 请求

    private static func get(path: String, cookie: String, session: URLSession) async throws -> Any {
        guard let url = URL(string: baseURL + path) else {
            throw QuotaError.network("无法构造请求地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue(baseURL + "/account/usage", forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                throw QuotaError.sessionExpired
            default:
                throw QuotaError.network("HTTP \(http.statusCode)")
            }
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("<html") {
                throw QuotaError.sessionExpired
            }
            throw QuotaError.decoding("响应不是合法 JSON")
        }
    }

    // MARK: - 凭据

    /// 归一化 Cookie：用户只粘了值时补上键名。
    static func normalizedCookie(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("qoder_session_cookie=") {
            return trimmed
        }
        return "qoder_session_cookie=\(trimmed)"
    }

    /// 用最轻的接口确认会话是否有效。
    ///
    /// 登录页本身也会下发一张同名的匿名 Cookie，抓取时若只认名字就会存下
    /// 未登录的票。这里问一次 `/api/v1/me`：2xx 才算真的登录成功。
    public static func validateSession(
        cookie raw: String,
        session: URLSession = .shared
    ) async -> Bool {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? await get(
            path: "/api/v1/me",
            cookie: normalizedCookie(raw),
            session: session)) != nil
    }

    // MARK: - 解析

    static func makeSnapshot(
        user: Any,
        plan: Any,
        credits: Any,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        let userName = (user as? [String: Any]).flatMap { JSONSearch.string($0["name"]) }
        let userEmail = (user as? [String: Any]).flatMap { JSONSearch.string($0["email"]) }
        let accountLabel = userName ?? userEmail

        let planDict = plan as? [String: Any]
        let planTier = planDict.flatMap { JSONSearch.string($0["plan_tier_name"]) }
            ?? planDict.flatMap { JSONSearch.string($0["plan_tier"]) }
        let planName = displayName(forPlanTier: planTier)
        let nextRefreshMs = planDict.flatMap { JSONSearch.number($0["next_refresh_date"]) }
        let nextResetAt = nextRefreshMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let endMs = planDict.flatMap { JSONSearch.number($0["end_date"]) }
        let expiresAt = endMs.map { Date(timeIntervalSince1970: $0 / 1000) }

        let creditsDict = credits as? [String: Any]

        var windows: [QuotaWindow] = []
        var balance: CreditBalance?

        // 套餐内月度配额
        if let planQuota = creditsDict?["plan_quota"] as? [String: Any],
           let summary = planQuota["quota_summary"] as? [String: Any],
           let used = JSONSearch.number(summary["used_value"]),
           let total = JSONSearch.number(summary["limit_value"]),
           total > 0
        {
            windows.append(QuotaWindow(
                id: "monthly",
                title: "每月",
                usedRatio: used / total,
                resetsAt: nextResetAt,
                totalQuota: total,
                unit: "Credits"))
        }

        // 附加资源包剩余
        if let rpQuota = creditsDict?["resource_package_quota"] as? [String: Any],
           let summary = rpQuota["quota_summary"] as? [String: Any],
           let remaining = JSONSearch.number(summary["remaining_value"])
        {
            let total = JSONSearch.number(summary["limit_value"])
            balance = CreditBalance(remaining: remaining, total: total, unit: "Credits")
        }

        guard !windows.isEmpty || balance != nil else {
            throw QuotaError.decoding("响应里没有配额数据")
        }

        return QuotaSnapshot(
            accountLabel: accountLabel,
            planName: planName,
            windows: windows,
            balance: balance,
            expiresAt: expiresAt,
            updatedAt: now)
    }

    static func displayName(forPlanTier tier: String?) -> String {
        guard let tier else { return "Qoder CN" }
        switch tier.uppercased() {
        case "PLAN_TIER_COMMUNITY", "COMMUNITY":
            return "社区版"
        case "PLAN_TIER_PRO", "PRO":
            return "专业版"
        case "PLAN_TIER_PRO_PLUS", "PRO_PLUS", "PROPLUS":
            return "高级版"
        case "PLAN_TIER_ULTRA", "ULTRA":
            return "旗舰版"
        default:
            return tier.replacingOccurrences(of: "PLAN_TIER_", with: "").capitalized
        }
    }
}
