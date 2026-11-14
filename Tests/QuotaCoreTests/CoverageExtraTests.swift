import Foundation
@testable import QuotaCore

/// 缺失必填字段的提示是用户实际看到的错误文案，单独覆盖一下。
enum QuotaFetcherMissingCredentialTests {
    static let suite = TestSuite("缺失凭据字段提示", [
        ("千问只缺 Cookie 时只提示 Cookie", testQwenOnlyCookie),
        ("可选字段和默认值字段不提示", testOptionalAndDefaultFields),
        ("凭据完整时没有缺失字段", testCompleteCredential),
    ])

    static func testQwenOnlyCookie() throws {
        let names = QuotaFetcher.missingCredentialNames(
            for: QwenTokenPlanProvider.credentialFields,
            credential: ProviderCredential())
        // region 有 defaultValue，不该出现在提示里。
        try Expect.equal(names, ["控制台会话 Cookie"])
    }

    static func testOptionalAndDefaultFields() throws {
        let fields = [
            CredentialField(id: "required", title: "必填"),
            CredentialField(id: "optional", title: "可选", isOptional: true),
            CredentialField(id: "defaulted", title: "有默认值", defaultValue: "x"),
        ]
        let names = QuotaFetcher.missingCredentialNames(
            for: fields,
            credential: ProviderCredential())
        try Expect.equal(names, ["必填"])
    }

    static func testCompleteCredential() throws {
        let names = QuotaFetcher.missingCredentialNames(
            for: QwenTokenPlanProvider.credentialFields,
            credential: ProviderCredential(["cookie": "login_aliyunid_ticket=abc"]))
        try Expect.equal(names, [])
    }
}

enum ProviderHTTPTests {
    static let suite = TestSuite("共用 HTTP 骨架", [
        ("裸 Cookie 值补上键名", testCookieHeaderAddsName),
        ("已带键名的 Cookie 原样保留", testCookieHeaderKeepsExisting),
        ("登录页 HTML 当成会话过期", testHTMLLoginPageIsSessionExpired),
        ("非法 JSON 仍是解析错误", testInvalidJSONIsDecoding),
    ])

    static func testCookieHeaderAddsName() throws {
        try Expect.equal(
            CookieHeader.withName("qoder_session_cookie", raw: "  abc  "),
            "qoder_session_cookie=abc")
    }

    static func testCookieHeaderKeepsExisting() throws {
        try Expect.equal(
            CookieHeader.withName("qoder_session_cookie", raw: "qoder_session_cookie=abc"),
            "qoder_session_cookie=abc")
    }

    static func testHTMLLoginPageIsSessionExpired() throws {
        do {
            _ = try ProviderHTTP.jsonObject(
                from: Data("<html><body>login</body></html>".utf8),
                sessionHTMLMarkers: ["<html"])
            throw AssertionFailure(message: "应抛出会话过期", file: #file, line: #line)
        } catch let error as QuotaError {
            guard case .sessionExpired = error else {
                throw AssertionFailure(message: "应为 sessionExpired，实际 \(error)", file: #file, line: #line)
            }
        }
    }

    static func testInvalidJSONIsDecoding() throws {
        do {
            _ = try ProviderHTTP.jsonObject(from: Data("not-json".utf8))
            throw AssertionFailure(message: "应抛出解析错误", file: #file, line: #line)
        } catch let error as QuotaError {
            guard case .decoding = error else {
                throw AssertionFailure(message: "应为 decoding，实际 \(error)", file: #file, line: #line)
            }
        }
    }
}
