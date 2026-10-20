import Foundation

/// Cursor 订阅用量来源。
///
/// Cursor 没有开放查询个人用量的 API，这里复用 cursor.com 控制台页面自己调用的接口，
/// 用网页登录态 Cookie `WorkosCursorSessionToken` 鉴权：
///
/// - `GET https://cursor.com/api/usage-summary`：当前计费周期的套餐用量（金额单位是美分），
///   新版套餐还会给出 Auto / API 两个分项的已用百分比。
/// - `GET https://cursor.com/api/usage?user=<userId>`：旧版按请求次数计费的套餐，
///   usage-summary 里取不到套餐数据时退回这里。
public enum CursorProvider: QuotaProvider {
    public static let metadata = ProviderMetadata(
        id: ProviderID("cursor"),
        vendor: "Cursor",
        plan: "订阅用量",
        summary: "查询 Cursor 当前周期的每周剩余，以及 Account balance 里的剩余 Credits。",
        consoleURL: URL(string: "https://cursor.com/dashboard"),
        consoleHint:
            "两种获取方式任选其一：\n" +
            "①「登录获取」——在弹窗里登录一次即可，会话过期后再点一次重新获取；\n" +
            "② 手动——浏览器登录 cursor.com/dashboard，F12 → Application → Cookies → https://cursor.com，" +
            "复制 WorkosCursorSessionToken 的值。",
        webLogin: WebLoginSpec(
            // 控制台未登录时会跳到 authenticator.cursor.sh，登录完成后回到这里并下发 Cookie，
            // 不需要额外的落地页。
            url: URL(string: "https://cursor.com/dashboard")!,
            cookieName: sessionCookieName,
            targetFieldID: "cookie",
            hint: "在弹出的窗口里登录 Cursor（邮箱或 GitHub；Google 登录可能会被内嵌窗口拦截）。登录成功后 App 会自动取到会话凭据。")
    )

    public static let credentialFields: [CredentialField] = [
        CredentialField(
            id: "cookie",
            title: "会话 Cookie",
            hint: "只需 WorkosCursorSessionToken 的值（形如 user_…%3A%3AeyJ…）。会话过期后重新获取即可。",
            kind: .secret
        ),
    ]

    static let sessionCookieName = "WorkosCursorSessionToken"
    private static let baseURL = "https://cursor.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    public static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
        guard let raw = credential["cookie"] else {
            throw QuotaError.missingCredential("会话 Cookie")
        }
        let cookie = normalizedCookie(raw)

        let summary = try await get(path: "/api/usage-summary", cookie: cookie)
        // 控制台页面上的大字来自这个接口。usage-summary 的百分比可能是另一套账，
        // 会停在 0，不能拿它当主数字。
        let token = accessToken(fromCookie: cookie)
        async let periodTask = currentPeriodUsage(cookie: cookie, token: token)
        async let planInfoTask = planInfo(cookie: cookie, token: token)
        // Account balance 的「Credits available」：赠送额度加上 Stripe 预存（负数才是余额）。
        async let grantsTask = try? post(path: "/api/dashboard/get-client-visible-credit-grants", cookie: cookie)
        async let stripeTask = try? get(path: "/api/auth/stripe", cookie: cookie)
        let (period, planInfo, grants, stripe) = await (periodTask, planInfoTask, grantsTask, stripeTask)
        do {
            let snapshot = try makeSnapshot(
                summaryPayload: summary,
                periodPayload: period,
                grantsPayload: grants,
                stripePayload: stripe,
                planInfoPayload: planInfo)
            return WeeklyCache.apply(to: snapshot)
        } catch QuotaError.decoding {
            guard let userID = userID(fromCookie: cookie) else { throw QuotaError.decoding("响应里没有套餐用量数据") }
            let legacy = try await get(path: "/api/usage?user=\(userID)", cookie: cookie)
            return try makeLegacySnapshot(
                usagePayload: legacy,
                planName: membershipType(in: summary).map(displayName(forMembership:)))
        }
    }

    // MARK: - 请求

    /// 当前周期用量。服务端这个接口很慢，经常超时或只回不带 `planUsage` 的空壳，
    /// 所以编辑器用的 api2.cursor.sh 和网页接口同时发，谁先给出百分比就用谁。
    private static func currentPeriodUsage(cookie: String, token: String?) async -> Any? {
        await withTaskGroup(of: Any?.self) { group in
            if let token {
                group.addTask { try? await rpc("GetCurrentPeriodUsage", token: token) }
            }
            group.addTask { try? await post(path: "/api/dashboard/get-current-period-usage", cookie: cookie) }
            group.addTask {
                // 第一次常被慢请求拖住，稍后再补发一次网页接口。
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return try? await post(path: "/api/dashboard/get-current-period-usage", cookie: cookie)
            }
            var fallback: Any?
            for await value in group {
                if hasPlanPercent(value) {
                    group.cancelAll()
                    return value
                }
                if fallback == nil { fallback = value }
            }
            return fallback
        }
    }

    private static func planInfo(cookie: String, token: String?) async -> Any? {
        if let token, let value = try? await rpc("GetPlanInfo", token: token) {
            return value
        }
        return try? await post(path: "/api/dashboard/get-plan-info", cookie: cookie)
    }

    /// Cursor 编辑器调用的 Connect RPC。会话 Cookie 里 `::` 后面那段就是它认的 Bearer token。
    private static func rpc(_ method: String, token: String) async throws -> Any {
        guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)") else {
            throw QuotaError.network("无法构造请求地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.sessionExpired
            }
            throw QuotaError.network("HTTP \(http.statusCode)")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QuotaError.decoding("响应不是合法 JSON")
        }
    }

    static func hasPlanPercent(_ payload: Any?) -> Bool {
        guard let root = payload as? [String: Any],
              let plan = root["planUsage"] as? [String: Any]
        else { return false }
        return JSONSearch.number(plan["totalPercentUsed"]) != nil
    }

    private static func post(path: String, cookie: String) async throws -> Any {
        try await send(path: path, cookie: cookie, method: "POST", body: Data("{}".utf8))
    }

    private static func get(path: String, cookie: String) async throws -> Any {
        try await send(path: path, cookie: cookie, method: "GET", body: nil)
    }

    private static func send(path: String, cookie: String, method: String, body: Data?) async throws -> Any {
        guard let url = URL(string: baseURL + path) else {
            throw QuotaError.network("无法构造请求地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 45
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue(baseURL + "/dashboard", forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.sessionExpired
            }
            throw QuotaError.network("HTTP \(http.statusCode)")
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

    /// 归一化用户粘贴的凭据：只粘了值时补上键名；值里的 `::` 是解码后的形式，
    /// 服务端只认 URL 编码后的 `%3A%3A`。
    static func normalizedCookie(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\(sessionCookieName)=") {
            return trimmed
        }
        let value = trimmed.replacingOccurrences(of: "::", with: "%3A%3A")
        return "\(sessionCookieName)=\(value)"
    }

    /// 从 Cookie 里取出 `user_…::` 后面的 JWT。
    static func accessToken(fromCookie cookie: String) -> String? {
        let prefix = "\(sessionCookieName)="
        guard let range = cookie.range(of: prefix) else { return nil }
        let value = cookie[range.upperBound...].prefix { $0 != ";" }
        let decoded = String(value).removingPercentEncoding ?? String(value)
        let parts = decoded.components(separatedBy: "::")
        guard parts.count >= 2, let token = parts.last, !token.isEmpty else { return nil }
        return token
    }

    /// 从 Cookie 里取出用户 ID（`user_…`），旧版用量接口需要它。
    static func userID(fromCookie cookie: String) -> String? {
        let prefix = "\(sessionCookieName)="
        guard let range = cookie.range(of: prefix) else { return nil }
        let value = cookie[range.upperBound...].prefix { $0 != ";" }
        let decoded = String(value).removingPercentEncoding ?? String(value)
        guard let id = decoded.components(separatedBy: "::").first,
              id.hasPrefix("user_")
        else { return nil }
        return id
    }

    // MARK: - 解析

    /// 解析用量。取不到任何用量窗口时抛 `decoding`，调用方据此退回旧版接口。
    ///
    /// `periodPayload` 是控制台当前周期接口。它在的时候，百分比、重置时间都以它为准；
    /// `summaryPayload` 补套餐名、金额上限和按量付费。
    static func makeSnapshot(
        summaryPayload: Any,
        periodPayload: Any? = nil,
        grantsPayload: Any? = nil,
        stripePayload: Any? = nil,
        planInfoPayload: Any? = nil,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let root = summaryPayload as? [String: Any] else {
            throw QuotaError.decoding("用量响应格式不对")
        }
        let period = periodPayload as? [String: Any]
        let planUsage = period?["planUsage"] as? [String: Any]
        let weeklyPlan = Self.weeklyPlan(planInfoPayload)
        let cycleStart = date(period?["billingCycleStart"]) ?? date(root["billingCycleStart"])
        var resetsAt = weeklyPlan.resetsAt
            ?? date(period?["billingCycleEnd"])
            ?? date(root["billingCycleEnd"])
        let individual = root["individualUsage"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]

        var windows: [QuotaWindow] = []

        if let plan = individual?["plan"] as? [String: Any], plan["enabled"] as? Bool != false {
            let cycle = weeklyPlan.weekly
                ? (id: "weekly", title: "每周")
                : cycleWindow(start: cycleStart, end: resetsAt)
            let periodPercent = period.flatMap {
                JSONSearch.number(JSONSearch.findValue(forKeys: ["totalPercentUsed"], in: $0))
            }.map { $0 / 100 }
            let periodLimit = JSONSearch.number(planUsage?["limit"]).flatMap { $0 > 0 ? $0 : nil }
            let summaryLimit = JSONSearch.number(plan["limit"]).flatMap { $0 > 0 ? $0 : nil }
            let summaryUsed = JSONSearch.number(plan["used"])
            // 控制台大字跟当前周期接口的 totalPercentUsed 走。
            // 金额上限只在和这个百分比同一份数据里出现时才带上，避免把另一套账的额度配错。
            let ratio: Double?
            let quotaCents: Double?
            if let periodPercent {
                ratio = periodPercent
                quotaCents = periodLimit
            } else if let messagePercent = Self.percent(in: period?["displayMessage"])
                ?? Self.percent(in: period?["autoModelSelectedDisplayMessage"])
            {
                // 当前周期接口有时不再给 planUsage，百分比只留在展示文案里。
                ratio = messagePercent
                quotaCents = nil
            } else if !weeklyPlan.weekly, let summaryUsed, let summaryLimit {
                ratio = summaryUsed / summaryLimit
                quotaCents = summaryLimit
            } else if !weeklyPlan.weekly {
                ratio = JSONSearch.number(plan["totalPercentUsed"]).map { $0 / 100 }
                quotaCents = nil
            } else {
                // 周额度套餐的 usage-summary 会停在 0，不能拿来冒充每周已用。
                ratio = nil
                quotaCents = nil
            }
            if let ratio {
                windows.append(QuotaWindow(
                    id: cycle.id,
                    title: cycle.title,
                    usedRatio: ratio,
                    resetsAt: resetsAt,
                    totalQuota: quotaCents.map { $0 / 100 },
                    unit: "USD"))
            }
        }

        let credits = accountCredits(grantsPayload: grantsPayload, stripePayload: stripePayload)
        // 周额度接口有时不带百分比。没有百分比就不要拿月度 summary 的 0 充数，
        // 至少把 Account balance 的剩余 Credits 留下来。
        guard windows.contains(where: { $0.id == "monthly" || $0.id == "weekly" }) || credits != nil else {
            throw QuotaError.decoding("响应里没有套餐用量数据")
        }

        return QuotaSnapshot(
            planName: membershipType(in: summaryPayload).map(displayName(forMembership:)),
            windows: windows,
            balance: credits,
            updatedAt: now)
    }

    /// 网页 Account balance 里的「Credits available」。
    ///
    /// 赠送额度看 `remainingCents`；Stripe 的 `customerBalance` 单位是美分，
    /// 负数表示账户里还有预存，正数是欠款，不算剩余。两份都没有时返回 nil。
    static func accountCredits(grantsPayload: Any?, stripePayload: Any?) -> CreditBalance? {
        var cents = 0.0
        var found = false
        if let grants = creditGrants(in: grantsPayload) {
            found = true
            for grant in grants {
                if let remaining = JSONSearch.number(grant["remainingCents"] ?? grant["remaining_cents"]),
                   remaining > 0
                {
                    cents += remaining
                }
            }
        }
        if let stripe = stripePayload as? [String: Any],
           let balance = JSONSearch.number(stripe["customerBalance"])
        {
            found = true
            if balance < 0 {
                cents += -balance
            }
        }
        guard found else { return nil }
        return CreditBalance(remaining: cents / 100, unit: "USD")
    }

    private static func creditGrants(in payload: Any?) -> [[String: Any]]? {
        guard let payload else { return nil }
        if let grants = payload as? [[String: Any]] { return grants }
        guard let root = payload as? [String: Any] else { return nil }
        for key in ["grants", "creditGrants"] {
            if let grants = root[key] as? [[String: Any]] { return grants }
        }
        return nil
    }

    /// 解析旧版按请求次数计费的 `/api/usage`：
    /// `{"gpt-4": {"numRequests": 120, "maxRequestUsage": 500}, "startOfMonth": "…"}`。
    static func makeLegacySnapshot(
        usagePayload: Any,
        planName: String?,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let root = usagePayload as? [String: Any] else {
            throw QuotaError.decoding("用量响应格式不对")
        }
        // gpt-4 那一项就是「高级模型请求」配额，其余模型通常不限次数。
        let candidates = (["gpt-4"] + root.keys.sorted()).compactMap { root[$0] as? [String: Any] }
        guard let model = candidates.first(where: {
                  (JSONSearch.number($0["maxRequestUsage"]) ?? 0) > 0
              }),
              let max = JSONSearch.number(model["maxRequestUsage"])
        else {
            throw QuotaError.decoding("响应里没有套餐用量数据")
        }
        let used = JSONSearch.number(model["numRequests"]) ?? 0
        let resetsAt = date(root["startOfMonth"]).flatMap {
            Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: $0)
        }

        return QuotaSnapshot(
            planName: planName,
            windows: [QuotaWindow(
                id: "monthly",
                title: "每月",
                usedRatio: used / max,
                resetsAt: resetsAt,
                totalQuota: max,
                unit: "次")],
            updatedAt: now)
    }

    private static func membershipType(in payload: Any) -> String? {
        (payload as? [String: Any]).flatMap { JSONSearch.string($0["membershipType"]) }
    }

    static func displayName(forMembership type: String) -> String {
        switch type.lowercased() {
        case "free": "Free"
        case "free_trial": "Pro 试用"
        case "pro": "Pro"
        case "pro_plus", "pro-plus", "proplus": "Pro+"
        case "ultra": "Ultra"
        case "business", "team": "Business"
        case "enterprise": "Enterprise"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Premium 这类套餐的包含额度按周计算。周期和重置时间在 get-plan-info 里。
    static func weeklyPlan(_ payload: Any?) -> (weekly: Bool, resetsAt: Date?) {
        guard let root = payload as? [String: Any] else { return (false, nil) }
        let info = (root["planInfo"] as? [String: Any]) ?? root
        let weekly: Bool
        if let number = JSONSearch.number(info["includedUsagePeriod"]) {
            weekly = number == 2
        } else if let name = JSONSearch.string(info["includedUsagePeriod"])?.uppercased() {
            weekly = name.contains("WEEKLY")
        } else {
            weekly = false
        }
        return (weekly, date(info["includedUsageResetsAt"]))
    }

    /// 从 “You've used 3% of …” 里取出已用比例。
    static func percent(in value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        guard let range = text.range(of: #"(\d+(?:\.\d+)?)\s*%"#, options: .regularExpression) else {
            return nil
        }
        let number = text[range].filter { $0.isNumber || $0 == "." }
        return Double(number).map { $0 / 100 }
    }

    /// 周期不超过 8 天视为每周，否则视为每月。缺起止时间时按每月。
    static func cycleWindow(start: Date?, end: Date?) -> (id: String, title: String) {
        guard let start, let end else { return ("monthly", "每月") }
        let days = end.timeIntervalSince(start) / 86_400
        return days <= 8 ? ("weekly", "每周") : ("monthly", "每月")
    }

    /// 计费周期时间：ISO 8601 字符串（可能带毫秒），或秒 / 毫秒时间戳。
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, !string.allSatisfy(\.isNumber) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
        return JSONSearch.date(value)
    }
}

extension CursorProvider {
    /// 最近一次拿到的套餐用量窗口。
    ///
    /// 当前周期接口时灵时不灵，没拿到百分比时用上次的值顶上，直到它的重置时间过去。
    /// 主应用和小组件各自抓数据，所以放在两边都能读写的共享目录。
    enum WeeklyCache {
        struct Entry: Codable, Equatable {
            var id: String
            var title: String
            var usedRatio: Double
            var resetsAt: Date?
            var totalQuota: Double?
            var unit: String
            var savedAt: Date
        }

        private static let fileName = "cursor-plan-window.json"

        static var defaultURL: URL? {
            SharedStore.containerURL?.appendingPathComponent(fileName)
        }

        static func apply(to snapshot: QuotaSnapshot, now: Date = Date(), url: URL? = defaultURL) -> QuotaSnapshot {
            guard let url else { return snapshot }
            if let window = snapshot.windows.first(where: { $0.id == "weekly" || $0.id == "monthly" }) {
                save(Entry(
                    id: window.id,
                    title: window.title,
                    usedRatio: window.usedRatio,
                    resetsAt: window.resetsAt,
                    totalQuota: window.totalQuota,
                    unit: window.unit,
                    savedAt: now), to: url)
                return snapshot
            }
            guard let entry = load(from: url), isValid(entry, now: now) else { return snapshot }
            var result = snapshot
            result.windows.insert(QuotaWindow(
                id: entry.id,
                title: entry.title,
                usedRatio: entry.usedRatio,
                resetsAt: entry.resetsAt,
                totalQuota: entry.totalQuota,
                unit: entry.unit), at: 0)
            return result
        }

        /// 过了重置时间就作废；没有重置时间的最多沿用 7 天。
        static func isValid(_ entry: Entry, now: Date) -> Bool {
            if let resetsAt = entry.resetsAt { return resetsAt > now }
            return now.timeIntervalSince(entry.savedAt) < 7 * 86_400
        }

        static func load(from url: URL) -> Entry? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Entry.self, from: data)
        }

        static func save(_ entry: Entry, to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
