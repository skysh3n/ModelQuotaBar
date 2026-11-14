import Foundation

/// Qoder CN（全家桶）用量来源。
///
/// Qoder CN 没有公开查询个人用量的 REST API，用量页面（qoder.com.cn/account/usage）
/// 自身调用的内部接口如下：
///
/// - `GET /api/v1/me`：用户基本信息（昵称、邮箱）。
/// - `GET /api/v1/me/userplan`：当前订阅套餐（档位、计费周期、到期/刷新时间）。
/// - `GET /api/v2/me/usages/big_model_credits`：Credits 配额详情，
///   包含 plan_quota（套餐内月度配额）、resource_package_quota（附加资源包）
///   和 dedicated_resource_package_quota（专属资源包）。
///
/// 鉴权走阿里云 SSO，但业务域名下的会话凭据是 `qoder_session_cookie`：
/// SSO 登录跳回 qoder.com.cn 时才下发，接口只认它。
public enum QoderProvider: QuotaProvider {
    public static let metadata = ProviderMetadata(
        id: ProviderID("qoder"),
        vendor: "Qoder CN",
        plan: "Credits 用量",
        summary: "查询 Qoder CN 当前订阅周期的 Credits 配额、附加资源包与专属资源包剩余。",
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
        request.setValue(BrowserIdentity.safariOnMac, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue(baseURL + "/account/usage", forHTTPHeaderField: "Referer")

        let (data, http) = try await ProviderHTTP.send(request, session: session)
        try ProviderHTTP.validate(http, authFailure: .sessionExpired)
        return try ProviderHTTP.jsonObject(from: data, sessionHTMLMarkers: ["<html"])
    }

    // MARK: - 凭据

    /// 归一化 Cookie：用户只粘了值时补上键名。
    static func normalizedCookie(_ raw: String) -> String {
        CookieHeader.withName("qoder_session_cookie", raw: raw)
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
        var resourcePackages: [ResourcePackageInfo] = []

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

        // 附加资源包（resource_package_quota）
        if let rpQuota = creditsDict?["resource_package_quota"] as? [String: Any],
           let packageInfo = parseResourcePackage(
               quota: rpQuota,
               defaultLabel: "附加资源包",
               sourceHint: "RESOURCE_PACKAGE")
        {
            resourcePackages.append(packageInfo)
        }

        // 专属资源包（dedicated_resource_package_quota）
        if let drpQuota = creditsDict?["dedicated_resource_package_quota"] as? [String: Any],
           let packageInfo = parseResourcePackage(
               quota: drpQuota,
               defaultLabel: "专属资源包",
               sourceHint: "DEDICATED_RESOURCE_PACKAGE")
        {
            resourcePackages.append(packageInfo)
        }

        guard !windows.isEmpty || !resourcePackages.isEmpty else {
            throw QuotaError.decoding("响应里没有配额数据")
        }

        return QuotaSnapshot(
            accountLabel: accountLabel,
            planName: planName,
            windows: windows,
            resourcePackages: resourcePackages,
            expiresAt: expiresAt,
            updatedAt: now)
    }

    // MARK: - 资源包解析

    /// 解析一块资源包（附加 / 专属），返回 nil 表示该块无有效数据。
    ///
    /// - Parameters:
    ///   - quota: `resource_package_quota` 或 `dedicated_resource_package_quota` 的字典。
    ///   - defaultLabel: display_labels 取不到标题时的兜底文案。
    ///   - sourceHint: 用于按 source 字段推断标题的提示。
    private static func parseResourcePackage(
        quota: [String: Any],
        defaultLabel: String,
        sourceHint: String
    ) -> ResourcePackageInfo? {
        // 优先从 quota_summary 取汇总；缺失时退化到 quota_detail 求和。
        let summary = quota["quota_summary"] as? [String: Any]
        let detail = quota["quota_detail"] as? [Any] ?? []

        let remaining: Double?
        let total: Double?
        let unit: String

        if let summary,
           let r = JSONSearch.number(summary["remaining_value"])
        {
            remaining = r
            total = JSONSearch.number(summary["limit_value"])
            unit = (summary["unit"] as? String) ?? "credits"
        } else if !detail.isEmpty {
            // 退化：把 detail 里每条的 remaining / limit 加起来。
            var sumRemaining: Double = 0
            var sumTotal: Double = 0
            var hasData = false
            for entry in detail {
                guard let item = entry as? [String: Any] else { continue }
                if let r = JSONSearch.number(item["remaining_value"]) {
                    sumRemaining += r
                    hasData = true
                }
                if let l = JSONSearch.number(item["limit_value"]) {
                    sumTotal += l
                }
            }
            guard hasData else { return nil }
            remaining = sumRemaining
            total = sumTotal > 0 ? sumTotal : nil
            unit = "credits"
        } else {
            return nil
        }

        // 全零且无明细时不塞假包。
        if remaining == 0, (total == nil || total == 0), detail.isEmpty {
            return nil
        }

        // 标题：优先 display_labels → 按 source 映射 → 兜底 defaultLabel。
        let label = extractTitle(from: detail, defaultLabel: defaultLabel, sourceHint: sourceHint)

        // 到期时间：取 detail 里最晚的 expires_at（毫秒时间戳）。
        let expiresAt = extractLatestExpiresAt(from: detail)

        return ResourcePackageInfo(
            remaining: remaining ?? 0,
            total: total,
            unit: unit.uppercased() == "CREDITS" ? "Credits" : unit,
            label: label,
            expiresAt: expiresAt)
    }

    /// 从 quota_detail 里提取展示标题。
    ///
    /// 优先级：
    /// 1. display_labels 中 dimension=title 的 value_i18n.zh-CN
    /// 2. display_labels 中 dimension=title 的 value_i18n.en-US
    /// 3. display_labels 中 dimension=title 的 value
    /// 4. 按 source 字段映射中文名
    /// 5. 兜底 defaultLabel
    private static func extractTitle(
        from detail: [Any],
        defaultLabel: String,
        sourceHint: String
    ) -> String {
        // 尝试从任意一条 detail 里取 display_labels。
        for entry in detail {
            guard let item = entry as? [String: Any],
                  let labels = item["display_labels"] as? [Any]
            else { continue }

            for labelEntry in labels {
                guard let label = labelEntry as? [String: Any],
                      let dimension = label["dimension"] as? String,
                      dimension == "title"
                else { continue }

                // 优先 zh-CN
                if let i18n = label["value_i18n"] as? [String: String],
                   let zhCN = i18n["zh-CN"], !zhCN.isEmpty
                {
                    return zhCN
                }
                // 退化 en-US
                if let i18n = label["value_i18n"] as? [String: String],
                   let enUS = i18n["en-US"], !enUS.isEmpty
                {
                    return enUS
                }
                // 退化 value
                if let value = label["value"] as? String, !value.isEmpty {
                    return value
                }
            }
        }

        // 按 source 映射
        for entry in detail {
            guard let item = entry as? [String: Any],
                  let source = item["source"] as? String
            else { continue }
            return titleForSource(source, default: defaultLabel)
        }

        // 兜底：按 sourceHint 映射
        return titleForSource(sourceHint, default: defaultLabel)
    }

    /// 按 source 字段推断中文标题。
    private static func titleForSource(_ source: String, default defaultLabel: String) -> String {
        switch source {
        case "DEDICATED_RESOURCE_PACKAGE":
            return "专属资源包"
        case "RESOURCE_PACKAGE_SOURCE_BONUS",
             "RESOURCE_PACKAGE_SOURCE_CARRY_OVER":
            return "附加资源包"
        default:
            if source.hasPrefix("RESOURCE_PACKAGE_SOURCE_") {
                return "附加资源包"
            }
            return defaultLabel
        }
    }

    /// 从 quota_detail 里取最晚的 expires_at（毫秒时间戳）。
    private static func extractLatestExpiresAt(from detail: [Any]) -> Date? {
        var latest: Date?
        for entry in detail {
            guard let item = entry as? [String: Any],
                  let raw = JSONSearch.number(item["expires_at"]),
                  raw > 0
            else { continue }
            let date = Date(timeIntervalSince1970: raw / 1000)
            if latest == nil || date > latest! {
                latest = date
            }
        }
        return latest
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
