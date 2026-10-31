import Foundation
@testable import QuotaCore

/// 这轮修复对应的回归测试：站点相关元数据、Cookie 归一化、主窗口选择、Cursor 周期判断。
enum ProviderMetadataTests {
    static let suite = TestSuite("Provider 元数据与凭据归一化", [
        ("千问控制台/登录地址跟随站点", testQwenFollowsRegion),
        ("裸 ticket 含等号也能补 Cookie 名", testTicketWithEqualsGetsCookieName),
        ("完整 Cookie 头保持不变", testFullCookieHeaderIsPreserved),
        ("非有限数值解析为 nil", testNonFiniteNumberIsNil),
        ("主窗口优先每周而不是 5 小时", testPrimaryWindowPrefersWeekly),
    ])

    static func testQwenFollowsRegion() throws {
        let metadata = QwenTokenPlanProvider.metadata
        let cn = ProviderCredential(["region": QwenTokenPlanRegion.chinaMainland.rawValue])
        let intl = ProviderCredential(["region": QwenTokenPlanRegion.international.rawValue])

        try Expect.equal(
            metadata.consoleURL(for: cn)?.absoluteString,
            QwenTokenPlanRegion.chinaMainland.consoleURL.absoluteString)
        try Expect.equal(
            metadata.consoleURL(for: intl)?.host,
            "modelstudio.console.alibabacloud.com")

        try Expect.equal(metadata.webLogin(for: cn)?.url.host, "account.aliyun.com")
        try Expect.equal(metadata.webLogin(for: intl)?.url.host, "account.alibabacloud.com")
        try Expect.equal(
            metadata.webLogin(for: intl)?.postLoginURL,
            QwenTokenPlanRegion.international.consoleURL)
        // 缺省（没有 region 字段）仍是中国站。
        try Expect.equal(metadata.webLogin(for: ProviderCredential())?.url.host, "account.aliyun.com")
    }

    static func testTicketWithEqualsGetsCookieName() throws {
        // ticket 值里可能有 base64/padding 的等号，不能被误判为完整 Cookie 头。
        try Expect.equal(
            AliyunConsoleGatewayClient.normalizedCookie("abc=="),
            "login_aliyunid_ticket=abc==")
        try Expect.equal(
            AliyunConsoleGatewayClient.normalizedCookie("  abc=="),
            "login_aliyunid_ticket=abc==")
    }

    static func testFullCookieHeaderIsPreserved() throws {
        let header = "foo=bar; login_aliyunid_ticket=abc==; cna=xyz"
        try Expect.equal(AliyunConsoleGatewayClient.normalizedCookie(header), header)
    }

    static func testNonFiniteNumberIsNil() throws {
        try Expect.isNil(JSONSearch.number("nan"))
        try Expect.isNil(JSONSearch.number("inf"))
        try Expect.isNil(JSONSearch.number("-inf"))
        try Expect.equal(JSONSearch.number(" 42.5 "), 42.5)
    }

    static func testPrimaryWindowPrefersWeekly() throws {
        let snapshot = QuotaSnapshot(windows: [
            QuotaWindow(id: "5h", title: "每 5 小时", usedRatio: 0.01),
            QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.4),
        ])
        try Expect.equal(snapshot.primaryWindow?.id, "weekly")
    }
}

enum CursorRegressionTests {
    static let suite = TestSuite("Cursor 回归", [
        ("plan-info 明确 monthly 时不被 Premium 兜底覆盖", testExplicitMonthlyWins),
        ("空壳 plan-info 不算有效", testHasPlanInfo),
        ("空 grants 对象不会把已有余额覆盖成 0", testEmptyGrantsNotAuthoritative),
        ("嵌套 data.grants 能识别", testNestedGrants),
        ("错误对象不被当成余额 0", testErrorObjectIsNotZero),
        ("展示文案里的百分比也算可用", testDisplayMessageIsUsable),
    ])

    static func testExplicitMonthlyWins() throws {
        let planInfo = try jsonObject("""
        { "planInfo": {
            "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_MONTHLY",
            "includedUsageResetsAt": 1792806998953 } }
        """)
        let result = CursorProvider.weeklyPlan(planInfo, membershipType: "premium")
        try Expect.isTrue(!result.weekly)
        try Expect.equal(result.resetsAt, Date(timeIntervalSince1970: 1_792_806_998.953))
    }

    static func testHasPlanInfo() throws {
        try Expect.isTrue(!CursorProvider.hasPlanInfo(try jsonObject("{}")))
        try Expect.isTrue(CursorProvider.hasPlanInfo(try jsonObject("""
        { "planInfo": { "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY" } }
        """)))
        try Expect.isTrue(CursorProvider.hasPlanInfo(try jsonObject("""
        { "includedUsageResetsAt": 1792806998953 }
        """)))
    }

    static func testEmptyGrantsNotAuthoritative() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-credits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_792_806_998)

        let withBalance = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.13, unit: "USD")],
            balance: CreditBalance(remaining: 12.5, unit: "USD"),
            updatedAt: now)
        _ = CursorProvider.CreditsCache.apply(to: withBalance, now: now, url: url)

        // grants 只回 {}：不是权威值，不能把 12.5 冲成 0。
        let empty = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.13, unit: "USD")],
            balance: CreditBalance(remaining: 0, unit: "USD"),
            updatedAt: now.addingTimeInterval(60))
        let preserved = CursorProvider.CreditsCache.apply(
            to: empty, now: now.addingTimeInterval(60), url: url, authoritative: false)
        try Expect.equal(try Expect.notNil(preserved.balance).remaining, 12.5, accuracy: 1e-9)

        // 真正的 0（grants 列表明确为空）仍应覆盖。
        let zeroed = CursorProvider.CreditsCache.apply(
            to: empty, now: now.addingTimeInterval(120), url: url, authoritative: true)
        try Expect.equal(try Expect.notNil(zeroed.balance).remaining, 0, accuracy: 1e-9)

        try Expect.isTrue(!CursorProvider.creditsAreAuthoritative(
            grantsPayload: try jsonObject("{}"), stripePayload: nil))
        try Expect.isTrue(CursorProvider.creditsAreAuthoritative(
            grantsPayload: try jsonObject(#"{"grants":[]}"#), stripePayload: nil))
    }

    static func testNestedGrants() throws {
        let payload = try jsonObject("""
        { "data": { "grants": [ { "remainingCents": 500 } ] } }
        """)
        let grants = try Expect.notNil(CursorProvider.creditGrants(in: payload))
        try Expect.equal(grants.count, 1)
        let balance = try Expect.notNil(
            CursorProvider.accountCredits(grantsPayload: payload, stripePayload: nil))
        try Expect.equal(balance.remaining, 5, accuracy: 1e-9)
    }

    static func testErrorObjectIsNotZero() throws {
        try Expect.isNil(CursorProvider.accountCredits(
            grantsPayload: try jsonObject(#"{"error":"boom"}"#),
            stripePayload: nil))
    }

    static func testDisplayMessageIsUsable() throws {
        try Expect.isTrue(CursorProvider.hasPlanPercent(try jsonObject("""
        { "displayMessage": "You've used 3% of your included usage" }
        """)))
        try Expect.isTrue(!CursorProvider.hasPlanPercent(try jsonObject("{}")))
    }
}
