import Foundation
@testable import QuotaCore

/// 千问 Token Plan 的解析测试。
///
/// 下面的 JSON 照抄自控制台网关的真实响应：字段名、信封层级、数值量级都不改，
/// 只把 token、账号标识之类的敏感值替换掉。
enum QwenTokenPlanParsingTests {
    /// `.../tokenplan/personal/api/v2/usage`
    static let usageJSON = """
    {
      "code": "200",
      "data": {
        "DataV2": {
          "data": {
            "success": true,
            "data": {
              "per5HourPercentage": 0.0009973083333333333,
              "per5HourResetTime": 1784813220000,
              "per1WeekPercentage": 0.0003014725,
              "per1WeekResetTime": 1785234900000
            }
          },
          "success": true,
          "httpStatus": 200
        }
      },
      "successResponse": true
    }
    """

    /// `.../tokenplan/personal/api/v2/subscription`
    static let subscriptionJSON = """
    {
      "code": "200",
      "data": {
        "DataV2": {
          "data": {
            "success": true,
            "data": {
              "instanceCode": "sfm_tokenplansolo_public_cn-redacted",
              "specCode": "pro",
              "status": "VALID",
              "remainingDays": 29,
              "autoRenewFlag": false,
              "startTime": 1784622404000,
              "endTime": 1787328000000
            }
          },
          "success": true,
          "httpStatus": 200
        }
      },
      "successResponse": true
    }
    """

    /// `.../tokenplan/personal/api/v2/quota-config`
    static let quotaConfigJSON = """
    {
      "code": "200",
      "data": {
        "DataV2": {
          "data": {
            "success": true,
            "data": {
              "lite": { "five_hour": 700, "weekly": 2500 },
              "standard": { "five_hour": 3000, "weekly": 10000 },
              "pro": { "five_hour": 12000, "weekly": 40000 }
            }
          },
          "success": true,
          "httpStatus": 200
        }
      },
      "successResponse": true
    }
    """

    static let suite = TestSuite("QwenTokenPlan · 解析", [
        ("从真实响应解析出用量窗口", testParsesUsageWindowsFromRealPayload),
        ("百分比是 0...1 比值而非百分数", testPercentageIsRatioNotPercent),
        ("按当前档位取出 Credits 总量", testAttachesCreditTotalsForCurrentTier),
        ("重置时间是毫秒时间戳", testParsesResetTimesAsMillisecondEpoch),
        ("5 小时窗口缺失时不补假数据", testOmitsFiveHourWindowWhenFieldAbsent),
        ("增值接口失败仍能出百分比", testStillReturnsWindowsWhenEnrichmentFails),
        ("解析用量包余额", testReadsAddonCreditBalance),
        ("没有任何用量窗口时报错", testThrowsWhenNoUsageWindowPresent),
        ("缺少 Cookie 时在发请求前就报错", testMissingCookieFailsBeforeRequest),
    ])

    static func testParsesUsageWindowsFromRealPayload() throws {
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: try jsonObject(subscriptionJSON),
            quotaConfigPayload: try jsonObject(quotaConfigJSON),
            region: .chinaMainland)

        try Expect.equal(snapshot.windows.map(\.id), ["5h", "weekly"])
        try Expect.equal(snapshot.planName, "Pro 专业版")
        try Expect.equal(snapshot.status, "VALID")
        try Expect.equal(snapshot.remainingDays, 29)
    }

    static func testPercentageIsRatioNotPercent() throws {
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            region: .chinaMainland)

        let fiveHour = try Expect.notNil(snapshot.windows.first { $0.id == "5h" })
        try Expect.equal(fiveHour.usedRatio, 0.0009973083333333333, accuracy: 1e-15)
    }

    static func testAttachesCreditTotalsForCurrentTier() throws {
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: try jsonObject(subscriptionJSON),
            quotaConfigPayload: try jsonObject(quotaConfigJSON),
            region: .chinaMainland)

        let weekly = try Expect.notNil(snapshot.windows.first { $0.id == "weekly" })
        // 套餐是 pro，必须取 pro 档的 weekly=40000，而不是 standard 的 10000。
        try Expect.equal(try Expect.notNil(weekly.totalQuota), 40_000)
    }

    static func testParsesResetTimesAsMillisecondEpoch() throws {
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            region: .chinaMainland)

        let weekly = try Expect.notNil(snapshot.windows.first { $0.id == "weekly" })
        try Expect.equal(
            try Expect.notNil(weekly.resetsAt),
            Date(timeIntervalSince1970: 1_785_234_900))
    }

    static func testOmitsFiveHourWindowWhenFieldAbsent() throws {
        let usage = """
        { "successResponse": true, "data": { "data": { "data": {
            "per1WeekPercentage": 0.2750906925,
            "per1WeekResetTime": 1785234900000 } } } }
        """
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usage),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            region: .chinaMainland)

        try Expect.equal(snapshot.windows.map(\.id), ["weekly"])
        try Expect.equal(snapshot.windows[0].usedRatio, 0.2750906925, accuracy: 1e-12)
    }

    static func testStillReturnsWindowsWhenEnrichmentFails() throws {
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            addonPayload: nil,
            region: .chinaMainland)

        try Expect.isTrue(!snapshot.windows.isEmpty)
        try Expect.isNil(snapshot.planName)
        try Expect.isNil(snapshot.balance)
    }

    static func testReadsAddonCreditBalance() throws {
        let addon = """
        { "successResponse": true, "data": { "data": { "data": {
            "remainingCredits": 18320.5, "totalCredits": 20000, "activeCount": 1 } } } }
        """
        let snapshot = try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(usageJSON),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            addonPayload: try jsonObject(addon),
            region: .chinaMainland)

        let balance = try Expect.notNil(snapshot.balance)
        try Expect.equal(balance.remaining, 18_320.5, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(balance.total), 20_000)
    }

    static func testThrowsWhenNoUsageWindowPresent() throws {
        let empty = """
        { "successResponse": true, "data": { "data": { "data": { "foo": 1 } } } }
        """
        try Expect.throwsError(try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try jsonObject(empty),
            subscriptionPayload: nil,
            quotaConfigPayload: nil,
            region: .chinaMainland))
    }

    static func testMissingCookieFailsBeforeRequest() throws {
        // 用信号量把 async 调用同步化，避免为了这一个用例引入完整的 async 测试支持。
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Error?

        Task {
            do {
                _ = try await QwenTokenPlanProvider.fetchSnapshot(credential: ProviderCredential())
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
}