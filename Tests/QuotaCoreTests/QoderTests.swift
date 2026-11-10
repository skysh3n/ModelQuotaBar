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
        ("专属资源包存在时解析出两块", testParsesDedicatedResourcePackage),
        ("专属资源包的 display_labels 取 zh-CN 标题", testDisplayLabelsTitle),
        ("total_quota 不被当成第三块", testTotalQuotaNotParsedAsPackage),
        ("只有附加包时是一块", testOnlyAddonPackageIsOne),
        ("两者都无时保持报错", testNoPackagesThrows),
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

    // MARK: - 专属资源包测试

    static func testParsesDedicatedResourcePackage() throws {
        let snapshot = try makeSnapshot(
            user: userInfo,
            plan: planInfo,
            credits: creditsWithDedicatedPayload)

        // 应有两块资源包：附加 + 专属
        try Expect.equal(snapshot.resourcePackages.count, 2)

        // 第一块是附加资源包
        let addon = snapshot.resourcePackages[0]
        try Expect.equal(addon.remaining, 0)
        try Expect.equal(addon.total, 1000)
        try Expect.equal(addon.label, "附加资源包")

        // 第二块是专属资源包
        let dedicated = snapshot.resourcePackages[1]
        try Expect.equal(dedicated.remaining, 1995)
        try Expect.equal(dedicated.total, 2000)
        try Expect.equal(dedicated.label, "Qwen 专属积分")

        // balance 取第一块（向后兼容）
        let balance = try Expect.notNil(snapshot.balance)
        try Expect.equal(balance.remaining, 0)
    }

    static func testDisplayLabelsTitle() throws {
        let snapshot = try makeSnapshot(
            user: userInfo,
            plan: planInfo,
            credits: creditsWithDedicatedPayload)

        // 专属包的标题应从 display_labels 取 zh-CN
        let dedicated = snapshot.resourcePackages[1]
        try Expect.equal(dedicated.label, "Qwen 专属积分")
    }

    static func testTotalQuotaNotParsedAsPackage() throws {
        let snapshot = try makeSnapshot(
            user: userInfo,
            plan: planInfo,
            credits: creditsWithDedicatedPayload)

        // total_quota 不应被解析为第三块包
        try Expect.equal(snapshot.resourcePackages.count, 2)

        // 各包的 remaining 之和应小于 total_quota（9000），避免重复计数
        let totalRemaining = snapshot.resourcePackages.reduce(0.0) { $0 + $1.remaining }
        try Expect.isTrue(totalRemaining < 9000)
    }

    static func testOnlyAddonPackageIsOne() throws {
        let snapshot = try makeSnapshot(
            user: userInfo,
            plan: planInfo,
            credits: creditsPayload)  // 没有 dedicated

        // 只有附加包时是一块
        try Expect.equal(snapshot.resourcePackages.count, 1)
        try Expect.equal(snapshot.resourcePackages[0].label, "附加资源包")
    }

    static func testNoPackagesThrows() throws {
        // plan_quota 有数据但两个资源包都为空，不应报错（仍有窗口）
        let onlyPlan = """
        {
          "plan_quota": {
            "quota_summary": {"used_value":10,"limit_value":1000,"remaining_value":990,"unit":"credits"}
          },
          "resource_package_quota": null,
          "dedicated_resource_package_quota": null
        }
        """
        let snapshot = try makeSnapshot(user: userInfo, plan: planInfo, credits: onlyPlan)
        try Expect.equal(snapshot.resourcePackages.count, 0)
        try Expect.equal(snapshot.windows.count, 1)

        // 完全没有数据时才报错
        let emptyCredits = """
        { "plan_quota": null, "resource_package_quota": null, "dedicated_resource_package_quota": null }
        """
        try Expect.throwsError(
            try makeSnapshot(user: userInfo, plan: planInfo, credits: emptyCredits)
        ) { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(message: "应为 decoding，实际 \(error)", file: #filePath, line: #line)
            }
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

    /// 包含专属资源包的真实响应结构（脱敏）
    private static let creditsWithDedicatedPayload = """
    {
      "plan_quota": {
        "quota_summary": {"used_value":26,"limit_value":6000,"remaining_value":5974,"usage_percentage":0,"unit":"credits"}
      },
      "resource_package_quota": {
        "quota_summary": {"used_value":1000,"limit_value":1000,"remaining_value":0,"usage_percentage":100,"unit":"credits"},
        "quota_detail": [
          {"source": "RESOURCE_PACKAGE_SOURCE_BONUS", "remaining_value": 0, "limit_value": 500, "expires_at": 1800000000000},
          {"source": "RESOURCE_PACKAGE_SOURCE_CARRY_OVER", "remaining_value": 0, "limit_value": 500, "expires_at": 1798000000000}
        ]
      },
      "dedicated_resource_package_quota": {
        "quota_summary": {"used_value":5,"limit_value":2000,"remaining_value":1995,"usage_percentage":0,"unit":"credits"},
        "quota_detail": [
          {
            "source": "DEDICATED_RESOURCE_PACKAGE",
            "remaining_value": 1995,
            "limit_value": 2000,
            "expires_at": 1800000000000,
            "name": "Qwen Package",
            "display_labels": [
              {"dimension": "title", "value": "qwen model series", "value_i18n": {"en-US": "Qwen Exclusive Credits", "zh-CN": "Qwen 专属积分"}},
              {"dimension": "description", "value_i18n": {"zh-CN": "Qwen 专属积分：在模型选择器中选择 Qwen 系列模型时优先抵扣该积分。"}}
            ]
          }
        ]
      },
      "total_quota": {
        "quota_summary": {"used_value":1031,"limit_value":9000,"remaining_value":7969,"usage_percentage":11,"unit":"credits"}
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
