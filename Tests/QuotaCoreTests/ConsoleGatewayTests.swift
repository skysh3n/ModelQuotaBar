import Foundation
@testable import QuotaCore

enum ConsoleGatewayTests {
    static let suite = TestSuite("阿里云控制台网关", [
        ("裸 ticket 自动补 Cookie 键名", testBareTicketGetsCookieNamePrefix),
        ("完整 Cookie 头原样保留", testFullCookieHeaderIsPreserved),
        ("两端空白被裁掉", testSurroundingWhitespaceIsTrimmed),
        ("表单编码转义保留字符", testFormEncodingEscapesReservedCharacters),
        ("表单编码按 UTF-8 处理中文", testFormEncodingPreservesUTF8),
        ("表单请求体拼接", testFormBodyJoinsPairs),
        ("两个站点的接入参数完全隔离", testRegionsAreFullyIsolated),
    ])

    /// 控制台里复制的通常只是 ticket 的值，而它的值本身不含 `=`。
    /// 直接当 Cookie 头发出去就没有 `name=value` 结构，网关一律判未登录，
    /// 表现得和「会话过期」一模一样——所以必须自动补键名。
    static func testBareTicketGetsCookieNamePrefix() throws {
        try Expect.equal(
            AliyunConsoleGatewayClient.normalizedCookie("abc123def456"),
            "login_aliyunid_ticket=abc123def456")
    }

    static func testFullCookieHeaderIsPreserved() throws {
        let header = "login_aliyunid_ticket=abc123; cna=xyz"
        try Expect.equal(AliyunConsoleGatewayClient.normalizedCookie(header), header)
    }

    static func testSurroundingWhitespaceIsTrimmed() throws {
        try Expect.equal(
            AliyunConsoleGatewayClient.normalizedCookie("  abc123\n"),
            "login_aliyunid_ticket=abc123")
    }

    /// 表单编码不能只按 RFC 3986 处理：`params` 里是整段 JSON，
    /// 未转义的 `&` 或 `+` 会把请求体切坏。
    static func testFormEncodingEscapesReservedCharacters() throws {
        try Expect.equal(FormEncoding.escape("a&b=c"), "a%26b%3Dc")
        try Expect.equal(FormEncoding.escape("+ /"), "%2B%20%2F")
        try Expect.equal(FormEncoding.escape("a-b_c.d~e"), "a-b_c.d~e")
    }

    static func testFormEncodingPreservesUTF8() throws {
        try Expect.equal(FormEncoding.escape("账"), "%E8%B4%A6")
    }

    static func testFormBodyJoinsPairs() throws {
        let body = FormEncoding.body([("region", "cn-beijing"), ("language", "zh-CN")])
        try Expect.equal(
            String(data: body, encoding: .utf8),
            "region=cn-beijing&language=zh-CN")
    }

    static func testRegionsAreFullyIsolated() throws {
        try Expect.equal(
            QwenTokenPlanRegion.chinaMainland.quotaBaseURL,
            "https://bailian-cs.console.aliyun.com")
        try Expect.equal(
            QwenTokenPlanRegion.international.quotaBaseURL,
            "https://bailian-singapore-cs.alibabacloud.com")
        try Expect.equal(QwenTokenPlanRegion.chinaMainland.gatewayAction, "BroadScopeAspnGateway")
        try Expect.equal(QwenTokenPlanRegion.international.gatewayAction, "IntlBroadScopeAspnGateway")
        try Expect.equal(QwenTokenPlanRegion.chinaMainland.regionID, "cn-beijing")
        try Expect.equal(QwenTokenPlanRegion.international.regionID, "ap-southeast-1")
        // 国际站的 consoleSite 含官方保留的历史拼写错误，必须原样照抄。
        try Expect.equal(QwenTokenPlanRegion.international.consoleSite, "MODELSTUDIO_ALBABACLOUD")
    }
}

enum JSONSearchTests {
    static let suite = TestSuite("JSON 深度查找", [
        ("在嵌套数组里命中对象", testFindsNestedDictionary),
        ("跨层级找第一个值", testFindsFirstValueForKeyAcrossDepth),
        ("跳过 null 值", testNullValuesAreSkipped),
        ("数字解析兼容字符串", testNumberParsesStringEncodedValues),
        ("时间戳兼容秒与毫秒", testDateHandlesSecondsAndMilliseconds),
    ])

    /// 网关的信封层级会变，查找必须能在任意深度命中。
    static func testFindsNestedDictionary() throws {
        let payload = try jsonObject("""
        { "a": { "b": [{ "c": { "specCode": "pro", "status": "VALID" } }] } }
        """)
        let found = try Expect.notNil(JSONSearch.findObject(
            containingAllOf: ["specCode", "status"],
            in: payload))
        try Expect.equal(found["specCode"] as? String, "pro")
    }

    static func testFindsFirstValueForKeyAcrossDepth() throws {
        let payload = try jsonObject("""
        { "outer": { "inner": { "per1WeekPercentage": 0.5 } } }
        """)
        try Expect.equal(
            JSONSearch.number(JSONSearch.findValue(forKeys: ["per1WeekPercentage"], in: payload)),
            0.5)
    }

    static func testNullValuesAreSkipped() throws {
        let payload = try jsonObject("""
        { "a": { "value": null }, "b": { "value": 7 } }
        """)
        try Expect.equal(JSONSearch.number(JSONSearch.findValue(forKeys: ["value"], in: payload)), 7)
    }

    static func testNumberParsesStringEncodedValues() throws {
        try Expect.equal(JSONSearch.number("42.5"), 42.5)
        try Expect.equal(JSONSearch.number(42), 42.0)
        try Expect.isNil(JSONSearch.number("not a number"))
    }

    static func testDateHandlesSecondsAndMilliseconds() throws {
        let expected = Date(timeIntervalSince1970: 1_785_234_900)
        try Expect.equal(JSONSearch.date(1_785_234_900), expected)
        try Expect.equal(JSONSearch.date(1_785_234_900_000), expected)
        try Expect.isNil(JSONSearch.date(0))
        try Expect.isNil(JSONSearch.date(nil))
    }
}

enum CredentialFieldTests {
    static let suite = TestSuite("凭据字段默认值", [
        ("有 defaultValue 的必填字段视为已完整", testDefaultValueSatisfiesCompleteness),
        ("resolvingDefaults 补上缺省但不覆盖已有值", testResolvingDefaultsFillsWithoutOverwrite),
        ("千问只有 Cookie 时也算配置完整", testQwenCookieAloneIsComplete),
    ])

    private static let regionField = CredentialField(
        id: "region",
        title: "站点",
        kind: .picker(options: [
            CredentialField.Option(id: "cn", title: "中国站"),
            CredentialField.Option(id: "intl", title: "国际站"),
        ]),
        defaultValue: "cn")

    private static let cookieField = CredentialField(
        id: "cookie",
        title: "控制台会话 Cookie",
        kind: .secret)

    static func testDefaultValueSatisfiesCompleteness() throws {
        let fields = [cookieField, regionField]
        try Expect.isTrue(!ProviderCredential(["cookie": "ticket"]).isComplete(for: [cookieField, CredentialField(id: "region", title: "站点")]))
        try Expect.isTrue(ProviderCredential(["cookie": "ticket"]).isComplete(for: fields))
        try Expect.isTrue(!ProviderCredential().isComplete(for: fields))
    }

    static func testResolvingDefaultsFillsWithoutOverwrite() throws {
        let fields = [cookieField, regionField]
        let filled = ProviderCredential(["cookie": "ticket"]).resolvingDefaults(for: fields)
        try Expect.equal(filled["region"], "cn")
        try Expect.equal(filled["cookie"], "ticket")

        let kept = ProviderCredential(["cookie": "ticket", "region": "intl"])
            .resolvingDefaults(for: fields)
        try Expect.equal(kept["region"], "intl")
    }

    static func testQwenCookieAloneIsComplete() throws {
        let fields = QwenTokenPlanProvider.credentialFields
        let credential = ProviderCredential(["cookie": "login_aliyunid_ticket=abc"])
        try Expect.isTrue(credential.isComplete(for: fields))
        let resolved = credential.resolvingDefaults(for: fields)
        try Expect.equal(resolved["region"], QwenTokenPlanRegion.chinaMainland.rawValue)
    }
}

enum QuotaWindowTests {
    static let suite = TestSuite("额度窗口模型", [
        ("已用比例被钳制到 0...1", testUsedRatioIsClamped),
        ("剩余比例是已用比例的补数", testRemainingRatioIsComplement),
        ("主窗口优先取月度", testPrimaryWindowPrefersMonthly),
        ("没有月度时退回第一个窗口", testPrimaryWindowFallsBackToFirst),
        ("未被钳制的进度条数值不会溢出", testProgressNeverExceedsOne),
    ])

    static func testUsedRatioIsClamped() throws {
        try Expect.equal(QuotaWindow(id: "x", title: "x", usedRatio: 1.4).usedRatio, 1)
        try Expect.equal(QuotaWindow(id: "x", title: "x", usedRatio: -0.3).usedRatio, 0)
    }

    static func testRemainingRatioIsComplement() throws {
        try Expect.equal(QuotaWindow(id: "x", title: "x", usedRatio: 0.25).remainingRatio, 0.75)
    }

    static func testPrimaryWindowPrefersMonthly() throws {
        let snapshot = QuotaSnapshot(windows: [
            QuotaWindow(id: "5h", title: "每 5 小时", usedRatio: 0.1),
            QuotaWindow(id: "monthly", title: "每月", usedRatio: 0.4),
            QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.2),
        ])
        try Expect.equal(snapshot.primaryWindow?.id, "monthly")
    }

    static func testPrimaryWindowFallsBackToFirst() throws {
        let snapshot = QuotaSnapshot(windows: [
            QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.2),
        ])
        try Expect.equal(snapshot.primaryWindow?.id, "weekly")
    }

    static func testProgressNeverExceedsOne() throws {
        let window = QuotaWindow(id: "x", title: "x", usedRatio: 0.99999999)
        try Expect.isTrue(window.usedRatio <= 1 && window.remainingRatio >= 0)
    }
}