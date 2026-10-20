import Foundation
@testable import QuotaCore

/// Cursor 的解析测试。
///
/// 样例按 cursor.com 控制台接口的字段结构构造：金额单位是美分，
/// 百分比是 0...100，计费周期是带毫秒的 ISO 8601 字符串。
enum CursorTests {
    static let suite = TestSuite("Cursor · 订阅用量解析", [
        ("新版套餐按 used/limit 计算每周剩余", testParsesNewPricingSummary),
        ("totalPercentUsed 与套餐额度不一致时以套餐额度为准", testIgnoresWeightedPoolPercent),
        ("赠送额度与 Stripe 预存相加为剩余 Credits", testAccountCredits),
        ("当前周期接口覆盖 usage-summary 里的 0", testPeriodUsageOverridesSummary),
        ("没有百分比时按 used / limit 计算", testFallsBackToUsedOverLimit),
        ("没有 planUsage 时从展示文案取每周已用比例", testPercentFromDisplayMessage),
        ("Premium 的每周额度不采用 usage-summary 的 0", testWeeklyPlanIgnoresEmptySummary),
        ("按量付费不单独占一行", testOnDemandIsNotShown),
        ("取不到套餐数据时报 decoding", testMissingPlanThrowsDecoding),
        ("套餐被禁用时报 decoding", testDisabledPlanThrowsDecoding),
        ("旧版按请求次数计费", testLegacyRequestBasedUsage),
        ("旧版接口没有配额时报 decoding", testLegacyWithoutQuotaThrows),
        ("套餐名映射", testMembershipDisplayNames),
        ("计费周期时间兼容多种格式", testDateFormats),
        ("只粘值时补上 Cookie 名", testNormalizesBareValue),
        ("解码后的 :: 会转回 %3A%3A", testNormalizesDecodedSeparator),
        ("整段 Cookie 原样保留", testKeepsFullCookieHeader),
        ("从 Cookie 里取用户 ID", testExtractsUserID),
        ("从 Cookie 里取 Bearer token", testExtractsAccessToken),
        ("周期接口没给百分比时沿用上次的每周用量，过了重置时间作废", testWeeklyCacheFillsMissingWindow),
        ("缺少 Cookie 时在发请求前报错", testMissingCookieFailsBeforeRequest),
        ("转成小组件快照", testWidgetSnapshot),
        ("已注册且小组件可选", testRegisteredAndSelectable),
    ])

    /// `GET /api/usage-summary`，新版按金额计费的 Pro 套餐。
    static let summaryJSON = """
    {
      "billingCycleStart": "2026-10-01T08:00:00.000Z",
      "billingCycleEnd": "2026-11-01T08:00:00.000Z",
      "membershipType": "pro",
      "limitType": "user",
      "isUnlimited": false,
      "individualUsage": {
        "plan": {
          "enabled": true,
          "used": 1234,
          "limit": 2000,
          "remaining": 766,
          "breakdown": { "included": 2000, "bonus": 0, "total": 1234 },
          "autoPercentUsed": 12.5,
          "apiPercentUsed": 48.0,
          "totalPercentUsed": 10.0
        },
        "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
      },
      "teamUsage": {}
    }
    """

    static func testParsesNewPricingSummary() throws {
        let snapshot = try makeSnapshot(summaryJSON)
        try Expect.equal(snapshot.planName, "Pro")
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])

        let monthly = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(monthly.id, "monthly")
        // 1234 / 2000，不用响应里的 totalPercentUsed（10%）。
        try Expect.equal(monthly.usedRatio, 0.617, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(monthly.totalQuota), 20.0, accuracy: 1e-9)
        try Expect.equal(monthly.unit, "USD")
        try Expect.equal(monthly.resetsAt, isoDate("2026-11-01T08:00:00Z"))
        try Expect.isNil(snapshot.balance)
    }

    static func testIgnoresWeightedPoolPercent() throws {
        // 真实响应里这两个数会差出一个数量级：控制台大字跟 used/limit 走。
        let snapshot = try makeSnapshot("""
        { "membershipType": "pro",
          "individualUsage": { "plan": {
            "enabled": true, "used": 1516, "limit": 2000,
            "autoPercentUsed": 3.297777777777778,
            "apiPercentUsed": 0.7111111111111111,
            "totalPercentUsed": 3.062626262626263 } } }
        """)
        try Expect.equal(try Expect.notNil(snapshot.primaryWindow).usedRatio, 1516.0 / 2000.0, accuracy: 1e-9)
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])
    }

    static func testPeriodUsageOverridesSummary() throws {
        let summary = try jsonObject("""
        { "membershipType": "premium",
          "billingCycleStart": "2026-10-01T00:00:00.000Z",
          "billingCycleEnd": "2026-11-01T00:00:00.000Z",
          "individualUsage": { "plan": {
            "enabled": true, "used": 0, "limit": 4615, "remaining": 4615,
            "autoPercentUsed": 0, "apiPercentUsed": 0, "totalPercentUsed": 0 } } }
        """)
        let period = try jsonObject("""
        { "billingCycleStart": "1792202198953", "billingCycleEnd": "1792806998953",
          "planUsage": { "autoPercentUsed": 3.5752979414951245, "apiPercentUsed": 0, "totalPercentUsed": 3.5752979414951245 },
          "displayMessage": "You've used 4% of your included usage" }
        """)
        let snapshot = try CursorProvider.makeSnapshot(summaryPayload: summary, periodPayload: period)
        let primary = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(primary.id, "weekly")
        try Expect.equal(primary.title, "每周")
        try Expect.equal(primary.usedRatio, 0.035752979414951245, accuracy: 1e-12)
        try Expect.isNil(primary.totalQuota)
        try Expect.equal(snapshot.windows.map(\.id), ["weekly"])
        try Expect.equal(primary.resetsAt, Date(timeIntervalSince1970: 1_792_806_998.953))
    }

    static func testAccountCredits() throws {
        let summary = try jsonObject(summaryJSON)
        let grants = try jsonObject("""
        { "grants": [
            {"remainingCents": "2100", "totalCents": 2500},
            {"remainingCents": 0, "totalCents": 100}
        ] }
        """)
        let stripe = try jsonObject(#"{"customerBalance": -500, "membershipType": "premium"}"#)
        let snapshot = try CursorProvider.makeSnapshot(
            summaryPayload: summary,
            grantsPayload: grants,
            stripePayload: stripe)
        let balance = try Expect.notNil(snapshot.balance)
        try Expect.equal(balance.remaining, 26.0, accuracy: 1e-9)
        try Expect.equal(balance.unit, "USD")
        let widget = snapshot.widgetSnapshot(id: CursorProvider.metadata.id, vendor: "Cursor")
        try Expect.equal(try Expect.notNil(widget.balanceRemaining), 26.0, accuracy: 1e-9)
        try Expect.equal(widget.balanceUnit, "USD")
        try Expect.equal(widget.primaryTitle, "每月")

        let zero = CursorProvider.accountCredits(
            grantsPayload: try jsonObject(#"{"grants":[]}"#),
            stripePayload: try jsonObject(#"{"customerBalance": 0}"#))
        try Expect.equal(try Expect.notNil(zero).remaining, 0, accuracy: 1e-9)
        // 正数是欠款，不记成剩余。
        let debt = CursorProvider.accountCredits(
            grantsPayload: nil,
            stripePayload: try jsonObject(#"{"customerBalance": 300}"#))
        try Expect.equal(try Expect.notNil(debt).remaining, 0, accuracy: 1e-9)
        try Expect.isNil(CursorProvider.accountCredits(grantsPayload: nil, stripePayload: nil))
    }

    static func testFallsBackToUsedOverLimit() throws {
        let snapshot = try makeSnapshot("""
        { "membershipType": "pro_plus",
          "billingCycleEnd": "2026-11-01T08:00:00Z",
          "individualUsage": { "plan": { "enabled": true, "used": 1500, "limit": 6000 } } }
        """)
        try Expect.equal(snapshot.planName, "Pro+")
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])
        try Expect.equal(snapshot.windows[0].usedRatio, 0.25, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(snapshot.windows[0].totalQuota), 60.0, accuracy: 1e-9)
    }

    static func testPercentFromDisplayMessage() throws {
        let summary = try jsonObject("""
        { "membershipType": "premium",
          "billingCycleStart": "2026-10-01T00:00:00.000Z",
          "billingCycleEnd": "2026-11-01T00:00:00.000Z",
          "individualUsage": { "plan": { "enabled": true, "used": 0, "limit": 4615, "totalPercentUsed": 0 } } }
        """)
        let period = try jsonObject("""
        { "billingCycleStart": "1792202198953", "billingCycleEnd": "1792806998953",
          "autoModelSelectedDisplayMessage": "You've used 3% of your included total usage",
          "namedModelSelectedDisplayMessage": "You've used 0% of your included API usage" }
        """)
        let snapshot = try CursorProvider.makeSnapshot(summaryPayload: summary, periodPayload: period)
        let primary = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(primary.title, "每周")
        try Expect.equal(primary.usedRatio, 0.03, accuracy: 1e-9)
        try Expect.equal(snapshot.windows.map(\.id), ["weekly"])
    }

    static func testWeeklyPlanIgnoresEmptySummary() throws {
        let summary = try jsonObject("""
        { "membershipType": "premium",
          "billingCycleStart": "2026-10-01T00:00:00.000Z",
          "billingCycleEnd": "2026-11-01T00:00:00.000Z",
          "individualUsage": { "plan": { "enabled": true, "used": 0, "limit": 4615, "totalPercentUsed": 0 } } }
        """)
        let period = try jsonObject("""
        { "billingCycleStart": "1790812800000", "billingCycleEnd": "1793491200000",
          "planUsage": { "totalPercentUsed": 3.8 } }
        """)
        let planInfo = try jsonObject("""
        { "planInfo": { "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
          "includedUsageResetsAt": "1792806998953" } }
        """)
        let snapshot = try CursorProvider.makeSnapshot(
            summaryPayload: summary,
            periodPayload: period,
            planInfoPayload: planInfo)
        let primary = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(primary.title, "每周")
        try Expect.equal(primary.usedRatio, 0.038, accuracy: 1e-9)
        try Expect.equal(primary.resetsAt, Date(timeIntervalSince1970: 1_792_806_998.953))

        // 周期接口没给百分比时，不能把月度 summary 的 0 画成每周剩 100%。
        try expectDecoding(try CursorProvider.makeSnapshot(
            summaryPayload: summary,
            periodPayload: try jsonObject(#"{"billingCycleStart":"1790812800000"}"#),
            planInfoPayload: planInfo))
    }

    static func testOnDemandIsNotShown() throws {
        let snapshot = try makeSnapshot("""
        { "membershipType": "pro",
          "individualUsage": {
            "plan": { "enabled": true, "used": 2000, "limit": 2000, "totalPercentUsed": 100 },
            "onDemand": { "enabled": true, "used": 500, "limit": 2000, "remaining": 1500 } } }
        """)
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])
    }

    static func testMissingPlanThrowsDecoding() throws {
        try expectDecoding(try makeSnapshot("""
        { "membershipType": "free", "individualUsage": {} }
        """))
        try expectDecoding(try makeSnapshot("[]"))
    }

    static func testDisabledPlanThrowsDecoding() throws {
        try expectDecoding(try makeSnapshot("""
        { "membershipType": "pro",
          "individualUsage": { "plan": { "enabled": false, "used": 0, "limit": 2000, "totalPercentUsed": 0 } } }
        """))
    }

    static func testLegacyRequestBasedUsage() throws {
        let payload = try jsonObject("""
        {
          "gpt-4": { "numRequests": 150, "numRequestsTotal": 180, "numTokens": 987654, "maxRequestUsage": 500, "maxTokenUsage": null },
          "gpt-3.5-turbo": { "numRequests": 30, "numRequestsTotal": 30, "numTokens": 1234, "maxRequestUsage": null, "maxTokenUsage": null },
          "startOfMonth": "2026-10-05T03:00:00.000Z"
        }
        """)
        let snapshot = try CursorProvider.makeLegacySnapshot(usagePayload: payload, planName: "Pro")
        try Expect.equal(snapshot.planName, "Pro")
        let window = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(window.id, "monthly")
        try Expect.equal(window.usedRatio, 0.3, accuracy: 1e-9)
        try Expect.equal(window.totalQuota, 500)
        try Expect.equal(window.unit, "次")
        try Expect.equal(window.resetsAt, isoDate("2026-11-05T03:00:00Z"))
    }

    static func testLegacyWithoutQuotaThrows() throws {
        let payload = try jsonObject("""
        { "gpt-4": { "numRequests": 10, "maxRequestUsage": null }, "startOfMonth": "2026-10-05T03:00:00.000Z" }
        """)
        try expectDecoding(try CursorProvider.makeLegacySnapshot(usagePayload: payload, planName: nil))
    }

    static func testMembershipDisplayNames() throws {
        try Expect.equal(CursorProvider.displayName(forMembership: "free"), "Free")
        try Expect.equal(CursorProvider.displayName(forMembership: "free_trial"), "Pro 试用")
        try Expect.equal(CursorProvider.displayName(forMembership: "PRO"), "Pro")
        try Expect.equal(CursorProvider.displayName(forMembership: "pro_plus"), "Pro+")
        try Expect.equal(CursorProvider.displayName(forMembership: "ultra"), "Ultra")
        try Expect.equal(CursorProvider.displayName(forMembership: "enterprise"), "Enterprise")
        try Expect.equal(CursorProvider.displayName(forMembership: "some_new_tier"), "Some New Tier")
    }

    static func testDateFormats() throws {
        let expected = isoDate("2026-11-01T08:00:00Z")
        try Expect.equal(CursorProvider.date("2026-11-01T08:00:00.000Z"), expected)
        try Expect.equal(CursorProvider.date("2026-11-01T08:00:00Z"), expected)
        try Expect.equal(CursorProvider.date(expected.timeIntervalSince1970 * 1000), expected)
        try Expect.equal(CursorProvider.date("\(Int(expected.timeIntervalSince1970))"), expected)
        try Expect.isNil(CursorProvider.date("not a date"))
        try Expect.isNil(CursorProvider.date(nil))
    }

    static func testNormalizesBareValue() throws {
        try Expect.equal(
            CursorProvider.normalizedCookie("  user_01ABC%3A%3AeyJhbGciOi.payload.sig \n"),
            "WorkosCursorSessionToken=user_01ABC%3A%3AeyJhbGciOi.payload.sig")
    }

    static func testNormalizesDecodedSeparator() throws {
        try Expect.equal(
            CursorProvider.normalizedCookie("user_01ABC::eyJhbGciOi.payload.sig"),
            "WorkosCursorSessionToken=user_01ABC%3A%3AeyJhbGciOi.payload.sig")
    }

    static func testKeepsFullCookieHeader() throws {
        let header = "foo=bar; WorkosCursorSessionToken=user_01ABC%3A%3AeyJ.x.y; other=1"
        try Expect.equal(CursorProvider.normalizedCookie(header), header)
    }

    static func testExtractsUserID() throws {
        try Expect.equal(
            CursorProvider.userID(fromCookie: "foo=bar; WorkosCursorSessionToken=user_01ABC%3A%3AeyJ.x.y; other=1"),
            "user_01ABC")
        try Expect.equal(
            CursorProvider.userID(fromCookie: CursorProvider.normalizedCookie("user_01ABC::eyJ.x.y")),
            "user_01ABC")
        try Expect.isNil(CursorProvider.userID(fromCookie: "WorkosCursorSessionToken=eyJ.x.y"))
        try Expect.isNil(CursorProvider.userID(fromCookie: "foo=bar"))
    }

    static func testMissingCookieFailsBeforeRequest() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Error?
        Task {
            do {
                _ = try await CursorProvider.fetchSnapshot(credential: ProviderCredential())
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

    static func testWidgetSnapshot() throws {
        let snapshot = try makeSnapshot(summaryJSON)
        let widget = snapshot.widgetSnapshot(id: CursorProvider.metadata.id, vendor: "Cursor")
        try Expect.equal(widget.id, "cursor")
        try Expect.equal(widget.planName, "Pro")
        try Expect.equal(widget.primaryTitle, "每月")
        try Expect.equal(try Expect.notNil(widget.primaryRemainingRatio), 0.383, accuracy: 1e-9)
        try Expect.isNil(widget.balanceRemaining)
        try Expect.isTrue(!widget.isBalanceOnly)
        try Expect.equal(widget.secondaryWindows.map(\.id), [])
    }

    static func testExtractsAccessToken() throws {
        try Expect.equal(
            CursorProvider.accessToken(fromCookie: "foo=bar; WorkosCursorSessionToken=user_01ABC%3A%3AeyJ.x.y; other=1"),
            "eyJ.x.y")
        try Expect.equal(
            CursorProvider.accessToken(fromCookie: CursorProvider.normalizedCookie("user_01ABC::eyJ.x.y")),
            "eyJ.x.y")
        try Expect.isNil(CursorProvider.accessToken(fromCookie: "WorkosCursorSessionToken=eyJ.x.y"))
    }

    static func testWeeklyCacheFillsMissingWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = isoDate("2026-10-19T08:00:00Z")
        let resetsAt = isoDate("2026-10-24T08:00:00Z")
        let credits = CreditBalance(remaining: 0, unit: "USD")

        let fresh = QuotaSnapshot(
            planName: "Premium",
            windows: [QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.037, resetsAt: resetsAt, unit: "USD")],
            balance: credits,
            updatedAt: now)
        _ = CursorProvider.WeeklyCache.apply(to: fresh, now: now, url: url)

        let empty = QuotaSnapshot(planName: "Premium", windows: [], balance: credits, updatedAt: now)
        let filled = CursorProvider.WeeklyCache.apply(to: empty, now: now.addingTimeInterval(3600), url: url)
        let window = try Expect.notNil(filled.windows.first)
        try Expect.equal(window.id, "weekly")
        try Expect.equal(window.usedRatio, 0.037, accuracy: 1e-9)
        try Expect.equal(window.resetsAt, resetsAt)

        let expired = CursorProvider.WeeklyCache.apply(to: empty, now: resetsAt.addingTimeInterval(1), url: url)
        try Expect.equal(expired.windows.count, 0)
    }

    static func testRegisteredAndSelectable() throws {
        let descriptor = try Expect.notNil(ProviderRegistry.descriptor(for: ProviderID("cursor")))
        try Expect.equal(descriptor.metadata.vendor, "Cursor")
        try Expect.equal(descriptor.metadata.webLogin?.cookieName, "WorkosCursorSessionToken")
        try Expect.equal(descriptor.metadata.webLogin?.targetFieldID, descriptor.credentialFields.first?.id)
        try Expect.isNil(descriptor.metadata.webLogin?.postLoginURL)
        try Expect.equal(WidgetSource.cursor.rawValue, CursorProvider.metadata.id.rawValue)
    }

    // MARK: - 工具

    private static func makeSnapshot(_ text: String) throws -> QuotaSnapshot {
        try CursorProvider.makeSnapshot(summaryPayload: try jsonObject(text))
    }

    private static func isoDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static func expectDecoding<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try Expect.throwsError(try expression(), { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(message: "应为 decoding，实际 \(error)", file: "\(file)", line: line)
            }
        }, file: file, line: line)
    }
}
