import Foundation

/// 千问 Token Plan（个人版）额度来源。
///
/// 官方没有开放查询套餐用量的 OpenAPI，本 Provider 复用百炼控制台自身的网关通道，
/// 需要用户提供控制台会话 Cookie。团队版走的是另一套 BSS 接口，暂未支持。
public enum QwenTokenPlanProvider: QuotaProvider {
    public static let metadata = ProviderMetadata(
        id: ProviderID("qwen-token-plan"),
        vendor: "通义千问",
        plan: "Token Plan",
        summary: "查询百炼 Token Plan 个人版的 5 小时 / 每周 / 每月额度用量与剩余 Credits。",
        consoleURL: QwenTokenPlanRegion.chinaMainland.consoleURL,
        consoleHint:
            "两种获取方式任选其一：\n" +
            "①「登录获取」——在弹窗里登录一次即可，会话过期后再点一次重新获取；\n" +
            "② 手动——控制台 F12 → Network → 任一发往 bailian-cs.console.aliyun.com 的请求，" +
            "复制 Request Headers 里 login_aliyunid_ticket 的值。",
        webLogin: WebLoginSpec(
            // 直接打开登录页，用户点「登录获取」就能看到登录表单。
            url: URL(string: "https://account.aliyun.com/login/login.htm")!,
            // 登录成功后要落回控制台，login_aliyunid_ticket 是这一步才下发的。
            postLoginURL: QwenTokenPlanRegion.chinaMainland.consoleURL,
            cookieName: "login_aliyunid_ticket",
            targetFieldID: "cookie",
            hint: "在弹出的窗口里登录百炼控制台。登录成功后 App 会自动取到会话凭据。")
    )

    public static let credentialFields: [CredentialField] = [
        CredentialField(
            id: "cookie",
            title: "控制台会话 Cookie",
            hint: "只需 login_aliyunid_ticket 的值。会话通常数周后过期，过期后重新复制即可。",
            kind: .secret
        ),
        CredentialField(
            id: "region",
            title: "站点",
            hint: "与购买套餐时的站点保持一致。",
            kind: .picker(options: QwenTokenPlanRegion.allCases.map {
                CredentialField.Option(id: $0.rawValue, title: $0.displayName)
            }),
            defaultValue: QwenTokenPlanRegion.chinaMainland.rawValue
        ),
    ]

    public static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
        guard let cookie = credential["cookie"] else {
            throw QuotaError.missingCredential("控制台会话 Cookie")
        }
        let region = credential["region"].flatMap(QwenTokenPlanRegion.init(rawValue:))
            ?? .chinaMainland

        let client = AliyunConsoleGatewayClient(region: region, cookieHeader: cookie)

        // usage 是必须的；subscription 与 quota-config 只影响套餐名和 Credits 总数，
        // 拿不到也应该照常展示百分比，因此单独容错。
        async let usagePayload = client.call(api: API.usage)
        async let subscriptionPayload = try? client.call(api: API.subscription)
        async let quotaConfigPayload = try? client.call(api: API.quotaConfig)
        async let addonPayload = try? client.call(api: API.addonSummary)

        let usage = try await usagePayload
        let subscription = await subscriptionPayload
        let quotaConfig = await quotaConfigPayload
        let addon = await addonPayload

        return try Self.makeSnapshot(
            usagePayload: usage,
            subscriptionPayload: subscription,
            quotaConfigPayload: quotaConfig,
            addonPayload: addon,
            region: region
        )
    }

    // MARK: - 接口路径

    private enum API {
        static let prefix = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2"
        static let usage = "\(prefix)/usage"
        static let subscription = "\(prefix)/subscription"
        static let quotaConfig = "\(prefix)/quota-config"
        static let addonSummary = "\(prefix)/addon/summary"
    }

    // MARK: - 解析

    static func makeSnapshot(
        usagePayload: Any,
        subscriptionPayload: Any?,
        quotaConfigPayload: Any?,
        addonPayload: Any? = nil,
        region: QwenTokenPlanRegion,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let usage = JSONSearch.findObject(
            containingAnyOf: ["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"],
            in: usagePayload)
        else {
            throw QuotaError.decoding("响应里没有用量窗口，账号可能没有生效中的 Token Plan 订阅")
        }

        let planCode = subscriptionPayload.flatMap(Self.planCode(from:))
        let totals = quotaConfigPayload.flatMap { Self.quotaTotals(from: $0, planCode: planCode) }

        var windows: [QuotaWindow] = []

        // 官方已下线 5 小时窗口，字段缺失即跳过，不要补零。
        if let ratio = JSONSearch.number(usage["per5HourPercentage"]) {
            windows.append(QuotaWindow(
                id: "5h",
                title: "每 5 小时",
                usedRatio: ratio,
                resetsAt: JSONSearch.date(usage["per5HourResetTime"]),
                totalQuota: totals?.fiveHour,
                unit: "Credits"
            ))
        }
        if let ratio = JSONSearch.number(usage["per1WeekPercentage"]) {
            windows.append(QuotaWindow(
                id: "weekly",
                title: "每周",
                usedRatio: ratio,
                resetsAt: JSONSearch.date(usage["per1WeekResetTime"]),
                totalQuota: totals?.weekly,
                unit: "Credits"
            ))
        }
        if let ratio = JSONSearch.number(usage["per1MonthPercentage"]) {
            windows.append(QuotaWindow(
                id: "monthly",
                title: "每月",
                usedRatio: ratio,
                resetsAt: JSONSearch.date(usage["per1MonthResetTime"]),
                totalQuota: totals?.monthly,
                unit: "Credits"
            ))
        }

        guard !windows.isEmpty else {
            throw QuotaError.decoding("响应里没有可用的用量窗口")
        }

        let subscription = subscriptionPayload.flatMap {
            JSONSearch.findObject(containingAnyOf: ["specCode", "spec_code", "status"], in: $0)
        }
        // 用量包里本期剩余 Credits 也算「余额」，一并展示。
        let addon = addonPayload.flatMap {
            JSONSearch.findObject(containingAnyOf: ["remainingCredits", "totalCredits"], in: $0)
        }

        return QuotaSnapshot(
            planName: planCode.map(Self.displayName(forPlanCode:)),
            status: subscription.flatMap { JSONSearch.string($0["status"]) },
            windows: windows,
            balance: addon.flatMap { Self.addonBalance(from: $0) },
            expiresAt: JSONSearch.date(subscription?["endTime"]),
            remainingDays: JSONSearch.number(subscription?["remainingDays"]).map { Int($0) },
            updatedAt: now
        )
    }

    private static func planCode(from payload: Any) -> String? {
        guard let plan = JSONSearch.findObject(
            containingAnyOf: ["specCode", "spec_code", "planName", "plan_name"],
            in: payload)
        else { return nil }
        for key in ["specCode", "spec_code", "planName", "plan_name"] {
            if let value = JSONSearch.string(plan[key])?.lowercased() {
                return value
            }
        }
        return nil
    }

    private static func displayName(forPlanCode code: String) -> String {
        switch code {
        case "lite": "Lite 轻量版"
        case "essential": "Essential 基础版"
        case "standard": "Standard 标准版"
        case "pro": "Pro 专业版"
        case "max": "Max 尊享版"
        default: code.capitalized
        }
    }

    /// quota-config 返回形如 `{"pro": {"five_hour": 12000, "weekly": 40000}}`，
    /// 按当前套餐档位取出各窗口的 Credits 总量。
    private static func quotaTotals(
        from payload: Any,
        planCode: String?
    ) -> (fiveHour: Double?, weekly: Double?, monthly: Double?)? {
        guard let planCode,
              let quota = JSONSearch.findValue(forKeys: [planCode], in: payload) as? [String: Any]
        else { return nil }
        let fiveHour = JSONSearch.number(quota["five_hour"] ?? quota["fiveHour"])
        let weekly = JSONSearch.number(quota["weekly"])
        let monthly = JSONSearch.number(quota["monthly"])
        guard fiveHour != nil || weekly != nil || monthly != nil else { return nil }
        return (fiveHour, weekly, monthly)
    }

    private static func addonBalance(from payload: [String: Any]) -> CreditBalance? {
        guard let remaining = JSONSearch.number(payload["remainingCredits"]) else { return nil }
        return CreditBalance(
            remaining: remaining,
            total: JSONSearch.number(payload["totalCredits"]),
            unit: "Credits"
        )
    }
}