import Foundation
@testable import QuotaCore

enum DeepSeekTests {
    static let suite = TestSuite("DeepSeek · 余额解析", [
        ("解析人民币余额", testParsesCNYBalance),
        ("多种币种时优先人民币", testPrefersCNY),
        ("没有人民币时退回唯一币种", testFallsBackToOnlyCurrency),
        ("is_available 为 false 时透出", testReflectsUnavailable),
        ("金额是字符串也能解析", testParsesStringAmounts),
        ("缺少 API Key 时在发请求前报错", testMissingKeyFailsBeforeRequest),
        ("非法 JSON 报解析错误", testInvalidJSONThrows),
        ("币种符号映射", testCurrencySymbols),
    ])

    static func testParsesCNYBalance() throws {
        let snapshot = try makeSnapshot(payload: cnyAndUsd)
        let balance = try Expect.notNil(snapshot.balance)
        try Expect.equal(balance.remaining, 110.0)
        try Expect.equal(balance.unit, "CNY")
        try Expect.equal(snapshot.isAvailable, true)
        try Expect.isTrue(snapshot.windows.isEmpty)
    }

    static func testPrefersCNY() throws {
        // 数组顺序故意把 USD 放前面，仍应优先取 CNY。
        let payload = """
        { "is_available": true, "balance_infos": [
            {"currency":"USD","total_balance":"15.43","granted_balance":"0.00","topped_up_balance":"15.43"},
            {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}
        ] }
        """
        let snapshot = try makeSnapshot(payload: payload)
        try Expect.equal(try Expect.notNil(snapshot.balance).remaining, 110.0)
        try Expect.equal(try Expect.notNil(snapshot.balance).unit, "CNY")
    }

    static func testFallsBackToOnlyCurrency() throws {
        let payload = """
        { "is_available": true, "balance_infos": [
            {"currency":"USD","total_balance":"15.43","granted_balance":"0.00","topped_up_balance":"15.43"}
        ] }
        """
        let snapshot = try makeSnapshot(payload: payload)
        try Expect.equal(try Expect.notNil(snapshot.balance).remaining, 15.43)
        try Expect.equal(try Expect.notNil(snapshot.balance).unit, "USD")
    }

    static func testReflectsUnavailable() throws {
        let payload = """
        { "is_available": false, "balance_infos": [
            {"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}
        ] }
        """
        let snapshot = try makeSnapshot(payload: payload)
        try Expect.equal(snapshot.isAvailable, false)
    }

    static func testParsesStringAmounts() throws {
        // 官方把金额序列化成字符串，必须是字符串解析。
        let payload = """
        { "is_available": true, "balance_infos": [
            {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}
        ] }
        """
        let snapshot = try makeSnapshot(payload: payload)
        try Expect.equal(try Expect.notNil(snapshot.balance).remaining, 110.0)
    }

    static func testMissingKeyFailsBeforeRequest() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Error?
        Task {
            do {
                _ = try await DeepSeekProvider.fetchSnapshot(credential: ProviderCredential())
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

    static func testInvalidJSONThrows() throws {
        try Expect.throwsError(
            try DeepSeekProvider.makeSnapshot(from: Data("not json".utf8))
        ) { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(message: "应为 decoding，实际 \(error)", file: #filePath, line: #line)
            }
        }
    }

    static func testCurrencySymbols() throws {
        try Expect.equal(CurrencySymbol.prefix(for: "CNY"), "¥")
        try Expect.equal(CurrencySymbol.prefix(for: "USD"), "$")
        try Expect.equal(CurrencySymbol.prefix(for: "EUR"), "€")
        try Expect.equal(CurrencySymbol.prefix(for: "ABC"), "ABC ")
        try Expect.equal(CurrencySymbol.format(110.0, unit: "CNY"), "¥110.00")
    }

    // MARK: - 工具

    private static let cnyAndUsd = """
    { "is_available": true, "balance_infos": [
        {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},
        {"currency":"USD","total_balance":"15.43","granted_balance":"0.00","topped_up_balance":"15.43"}
    ] }
    """

    private static func makeSnapshot(payload: String) throws -> QuotaSnapshot {
        try DeepSeekProvider.makeSnapshot(from: Data(payload.utf8))
    }
}