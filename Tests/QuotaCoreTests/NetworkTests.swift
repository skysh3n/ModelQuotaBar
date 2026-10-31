import Foundation
@testable import QuotaCore

/// 用 URLProtocol 拦掉真实网络，覆盖请求构造与 HTTP 状态映射。
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func mockResponse(
    _ status: Int,
    body: String,
    url: URL
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
    return (response, Data(body.utf8))
}

/// 把 async 调用桥回同步，和现有测试的风格保持一致。
private func runAsync<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    return try Expect.notNil(result, "异步调用超时").get()
}

enum DeepSeekNetworkTests {
    static let suite = TestSuite("DeepSeek · 网络请求", [
        ("成功请求带 Bearer 并解析余额", testSuccessSendsBearer),
        ("401 映射为凭据无效", testUnauthorized),
        ("500 映射为网络错误", testServerError),
        ("非法 JSON 映射为解析错误", testInvalidJSON),
    ])

    static func testSuccessSendsBearer() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(200, body: """
            { "is_available": true, "balance_infos": [
                {"currency":"CNY","total_balance":"110.00"} ] }
            """, url: request.url!)
        }

        let snapshot = try runAsync {
            try await DeepSeekProvider.fetchSnapshot(
                credential: ProviderCredential(["apiKey": "sk-test"]),
                session: mockSession())
        }
        try Expect.equal(try Expect.notNil(snapshot.balance).remaining, 110, accuracy: 1e-9)

        let request = try Expect.notNil(MockURLProtocol.lastRequest)
        try Expect.equal(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
        try Expect.equal(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        try Expect.equal(request.httpMethod, "GET")
    }

    static func testUnauthorized() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(401, body: #"{"error":"unauthorized"}"#, url: request.url!)
        }

        try Expect.throwsError(try runAsync {
            try await DeepSeekProvider.fetchSnapshot(
                credential: ProviderCredential(["apiKey": "sk-bad"]),
                session: mockSession())
        }) { error in
            guard case QuotaError.invalidCredential = error else {
                throw AssertionFailure(
                    message: "应为 invalidCredential，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }

    static func testServerError() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(500, body: "", url: request.url!)
        }

        try Expect.throwsError(try runAsync {
            try await DeepSeekProvider.fetchSnapshot(
                credential: ProviderCredential(["apiKey": "sk-test"]),
                session: mockSession())
        }) { error in
            guard case let QuotaError.network(message) = error else {
                throw AssertionFailure(
                    message: "应为 network，实际 \(error)",
                    file: #filePath, line: #line)
            }
            try Expect.equal(message, "HTTP 500")
        }
    }

    static func testInvalidJSON() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(200, body: "not json", url: request.url!)
        }

        try Expect.throwsError(try runAsync {
            try await DeepSeekProvider.fetchSnapshot(
                credential: ProviderCredential(["apiKey": "sk-test"]),
                session: mockSession())
        }) { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(
                    message: "应为 decoding，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }
}

enum AliyunGatewayNetworkTests {
    static let suite = TestSuite("阿里云网关 · 请求/HTTP", [
        ("请求体包含网关信封字段", testRequestBodyEnvelope),
        ("call 构造 POST/查询参数/Cookie/Origin", testCallBuildsRequest),
        ("401 映射为会话过期", testUnauthorized),
        ("200 + HTML 登录页映射为会话过期", testHTMLLoginPage),
        ("200 + 非法 JSON 映射为解析错误", testInvalidJSON),
    ])

    static func testRequestBodyEnvelope() throws {
        let api = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
        let data = try AliyunConsoleGatewayClient.requestBody(api: api, region: .international)
        let body = try Expect.notNil(String(data: data, encoding: .utf8))

        let paramsEncoded = try Expect.notNil(
            body.split(separator: "&").first { $0.hasPrefix("params=") })
        let encoded = String(paramsEncoded.dropFirst("params=".count))
        let decoded = try Expect.notNil(encoded.removingPercentEncoding)
        let params = try Expect.notNil(
            try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any])

        try Expect.equal(params["Api"] as? String, api)
        try Expect.equal(params["V"] as? String, "1.0")
        let payload = try Expect.notNil(params["Data"] as? [String: Any])
        let cornerstone = try Expect.notNil(payload["cornerstoneParam"] as? [String: Any])
        try Expect.equal(cornerstone["domain"] as? String, "modelstudio.console.alibabacloud.com")
        try Expect.equal(cornerstone["consoleSite"] as? String, "MODELSTUDIO_ALBABACLOUD")
        try Expect.equal(cornerstone["protocol"] as? String, "V2")
        try Expect.equal(cornerstone["productCode"] as? String, "p_efm")
        // 不能带 switchAgent：写死 workspace 会让其他账号 NotAuthorised。
        try Expect.isNil(cornerstone["switchAgent"])

        try Expect.isTrue(body.contains("product=sfm_bailian"))
        try Expect.isTrue(body.contains("action=IntlBroadScopeAspnGateway"))
        try Expect.isTrue(body.contains("region=ap-southeast-1"))
    }

    static func testCallBuildsRequest() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(200, body: #"{"successResponse":true,"data":{"value":42}}"#, url: request.url!)
        }
        let client = AliyunConsoleGatewayClient(
            region: .chinaMainland,
            cookieHeader: "abc123",
            session: mockSession())
        let payload = try runAsync { try await client.call(api: "zeldaHttp.test/usage") }
        let dictionary = try Expect.notNil(payload as? [String: Any])
        let data = try Expect.notNil(dictionary["data"] as? [String: Any])
        try Expect.equal(data["value"] as? Int, 42)

        let request = try Expect.notNil(MockURLProtocol.lastRequest)
        try Expect.equal(request.httpMethod, "POST")
        let url = try Expect.notNil(request.url)
        try Expect.equal(url.host, "bailian-cs.console.aliyun.com")
        let query = try Expect.notNil(url.query?.removingPercentEncoding)
        try Expect.isTrue(query.contains("action=BroadScopeAspnGateway"))
        try Expect.isTrue(query.contains("product=sfm_bailian"))
        try Expect.isTrue(query.contains("api=zeldaHttp.test/usage"))

        try Expect.equal(
            request.value(forHTTPHeaderField: "Cookie"),
            "login_aliyunid_ticket=abc123")
        try Expect.equal(
            request.value(forHTTPHeaderField: "Origin"),
            "https://bailian.console.aliyun.com")
        try Expect.equal(
            request.value(forHTTPHeaderField: "Referer"),
            "https://bailian.console.aliyun.com/")
        try Expect.equal(
            request.value(forHTTPHeaderField: "X-Requested-With"),
            "XMLHttpRequest")
        try Expect.equal(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded")
    }

    static func testUnauthorized() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(401, body: "{}", url: request.url!)
        }
        let client = AliyunConsoleGatewayClient(
            region: .chinaMainland,
            cookieHeader: "abc",
            session: mockSession())
        try Expect.throwsError(try runAsync {
            try await client.call(api: "usage")
        }) { error in
            guard case QuotaError.sessionExpired = error else {
                throw AssertionFailure(
                    message: "应为 sessionExpired，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }

    static func testHTMLLoginPage() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(200, body: "<html><body>Please login</body></html>", url: request.url!)
        }
        let client = AliyunConsoleGatewayClient(
            region: .chinaMainland,
            cookieHeader: "abc",
            session: mockSession())
        try Expect.throwsError(try runAsync {
            try await client.call(api: "usage")
        }) { error in
            guard case QuotaError.sessionExpired = error else {
                throw AssertionFailure(
                    message: "应为 sessionExpired，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }

    static func testInvalidJSON() throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            mockResponse(200, body: "not json", url: request.url!)
        }
        let client = AliyunConsoleGatewayClient(
            region: .chinaMainland,
            cookieHeader: "abc",
            session: mockSession())
        try Expect.throwsError(try runAsync {
            try await client.call(api: "usage")
        }) { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(
                    message: "应为 decoding，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }
}
