import Foundation
@testable import QuotaCore

enum QoderTests {
    static let suite = TestSuite("Qoder CN · 配额解析", [
        ("解析套餐配额与附加包", testParsesPlanAndAddonQuota),
        ("用量包余额进入小组件快照", testAddonBalanceReachesWidgetSnapshot),
        ("套餐名映射", testPlanTierDisplayNames),
        ("缺少配额数据时报解析错误", testMissingQuotaThrows),
        ("Cookie 归一化", testCookieNormalization),
        ("缺少 Cookie 时在发请求前报错", testMissingCookieFailsBeforeRequest),
    ])

    static func testParsesPlanAndAddonQuota() throws {
        let snapshot = try makeSnapshot(
            user: userInfo,
            plan: planInfo,
            credits: creditsPayload)

        try Expect.equal(snapshot.accountLabel, "skyshen")
        try Expect.equal(snapshot.planName, "专业版")

        let monthly = snapshot.windows.first { $0.id == "monthly" }
        let window = try Expect.notNil(monthly)
        try Expect.equal(window.title, "每月")
        try Expect.equal(window.totalQuota, 2000)
        try Expect.equal(window.unit, "Credits")
        // 95 / 2000 = 0.0475
        try Expect.isTrue(abs(window.usedRatio - 0.0475) < 0.001)

        let balance = try Expect.notNil(snapshot.balance)
        try Expect.equal(balance.remaining, 100)
        try Expect.equal(balance.total, 500)
        try Expect.equal(balance.unit, "Credits")
    }

    static func testAddonBalanceReachesWidgetSnapshot() throws {
        let snapshot = try makeSnapshot(user: userInfo, plan: planInfo, credits: creditsPayload)
        let widget = snapshot.widgetSnapshot(id: QoderProvider.metadata.id, vendor: "Qoder CN")
        try Expect.equal(try Expect.notNil(widget.primaryRemainingRatio), 0.9525, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(widget.primaryTotalQuota), 2_000, accuracy: 1e-9)
        try Expect.equal(widget.primaryUnit, "Credits")
        try Expect.equal(try Expect.notNil(widget.balanceRemaining), 100, accuracy: 1e-9)
        try Expect.equal(widget.balanceUnit, "Credits")
        try Expect.isTrue(!widget.isBalanceOnly)
    }

    static func testPlanTierDisplayNames() throws {
        try Expect.equal(QoderProvider.displayName(forPlanTier: "PLAN_TIER_PRO"), "专业版")
        try Expect.equal(QoderProvider.displayName(forPlanTier: "PLAN_TIER_PRO_PLUS"), "高级版")
        try Expect.equal(QoderProvider.displayName(forPlanTier: "PLAN_TIER_ULTRA"), "旗舰版")
        try Expect.equal(QoderProvider.displayName(forPlanTier: "PLAN_TIER_COMMUNITY"), "社区版")
        try Expect.equal(QoderProvider.displayName(forPlanTier: nil), "Qoder CN")
    }

    static func testMissingQuotaThrows() throws {
        let emptyCredits = """
        { "plan_quota": null, "resource_package_quota": null, "total_quota": null }
        """
        try Expect.throwsError(
            try QoderProvider.makeSnapshot(
                user: JSONSerialization.jsonObject(with: Data(userInfo.utf8)),
                plan: JSONSerialization.jsonObject(with: Data(planInfo.utf8)),
                credits: JSONSerialization.jsonObject(with: Data(emptyCredits.utf8)))
        ) { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(message: "应为 decoding，实际 \(error)", file: #filePath, line: #line)
            }
        }
    }

    static func testCookieNormalization() throws {
        // 只粘贴了值
        try Expect.equal(
            QoderProvider.normalizedCookie("  session-abc  "),
            "qoder_session_cookie=session-abc")
        // 已带键名
        try Expect.equal(
            QoderProvider.normalizedCookie("qoder_session_cookie=session-abc"),
            "qoder_session_cookie=session-abc")
    }

    static func testMissingCookieFailsBeforeRequest() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Error?
        Task {
            do {
                _ = try await QoderProvider.fetchSnapshot(credential: ProviderCredential())
            } catch {
                captured = error
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        let error = try Expect.notNil(captured, "应当抛出 missingCredential")
        guard case QuotaError.missingCredential = error else {
            throw AssertionFailure(message: "错误类型不对：\(error)", file: #filePath, line: #line)
        }
    }

    // MARK: - 工具

    private static let userInfo = """
    {"id":"user-1","name":"skyshen","email":""}
    """

    private static let planInfo = """
    {"plan_tier":"PLAN_TIER_PRO","plan_tier_name":"PLAN_TIER_PRO","status":"USER_PLAN_STATUS_ACTIVE","next_refresh_date":1796313600000,"end_date":1796313600000}
    """

    private static let creditsPayload = """
    {
      "plan_quota": {
        "quota_summary": {"used_value":95,"limit_value":2000,"remaining_value":1905,"usage_percentage":5,"unit":"credits"}
      },
      "resource_package_quota": {
        "quota_summary": {"used_value":400,"limit_value":500,"remaining_value":100,"usage_percentage":80,"unit":"credits"}
      },
      "total_quota": {
        "quota_summary": {"used_value":495,"limit_value":2500,"remaining_value":2005,"usage_percentage":20,"unit":"credits"}
      },
      "nextResetAt": 1796313600000
    }
    """

    private static func makeSnapshot(user: String, plan: String, credits: String) throws -> QuotaSnapshot {
        try QoderProvider.makeSnapshot(
            user: JSONSerialization.jsonObject(with: Data(user.utf8)),
            plan: JSONSerialization.jsonObject(with: Data(plan.utf8)),
            credits: JSONSerialization.jsonObject(with: Data(credits.utf8)))
    }
}
