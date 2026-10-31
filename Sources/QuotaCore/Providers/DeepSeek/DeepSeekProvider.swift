import Foundation

/// DeepSeek 账户余额来源。
///
/// 和千问那边「官方不开放额度接口」不同，DeepSeek 有公开的余额接口：
/// `GET https://api.deepseek.com/user/balance`，用 API Key 做 Bearer 鉴权。
/// 返回的是充值余额（不是套餐窗口），所以这里只填 `QuotaSnapshot.balance`，
/// 不产生任何时间窗口。
public enum DeepSeekProvider: QuotaProvider {
    public static let metadata = ProviderMetadata(
        id: ProviderID("deepseek"),
        vendor: "DeepSeek",
        plan: "API 余额",
        summary: "查询 DeepSeek 开放平台的账户充值余额。",
        consoleURL: URL(string: "https://platform.deepseek.com/"),
        consoleHint: "在 platform.deepseek.com 登录后，右上角「API 密钥」里创建或复制一个 Key。"
    )

    public static let credentialFields: [CredentialField] = [
        CredentialField(
            id: "apiKey",
            title: "API Key",
            hint: "形如 sk-… 的密钥。只用于查余额，不会拿去做模型调用。",
            kind: .secret
        ),
    ]

    private static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
        try await fetchSnapshot(credential: credential, session: .shared)
    }

    /// 带 session 的版本供单测注入 URLProtocol；生产路径用 `.shared`。
    static func fetchSnapshot(
        credential: ProviderCredential,
        session: URLSession
    ) async throws -> QuotaSnapshot {
        guard let apiKey = credential["apiKey"] else {
            throw QuotaError.missingCredential("API Key")
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                throw QuotaError.invalidCredential("API Key 被拒绝，请检查是否复制完整")
            default:
                throw QuotaError.network("HTTP \(http.statusCode)")
            }
        }

        return try makeSnapshot(from: data, now: Date())
    }

    // MARK: - 解析

    static func makeSnapshot(from data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw QuotaError.decoding("余额响应不是合法 JSON")
        }

        // 账户可能同时有多种币种，优先展示人民币。
        let info = payload.balanceInfos.first { $0.currency == "CNY" }
            ?? payload.balanceInfos.first

        guard let info else {
            throw QuotaError.decoding("响应里没有 balance_infos")
        }
        guard let remaining = Double(info.totalBalance) else {
            throw QuotaError.decoding("余额数值无法解析：\(info.totalBalance)")
        }

        return QuotaSnapshot(
            isAvailable: payload.isAvailable,
            windows: [],
            balance: CreditBalance(remaining: remaining, total: nil, unit: info.currency),
            updatedAt: now)
    }

    private struct Payload: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        /// 官方把金额序列化成字符串，例如 "110.00"。
        let totalBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
        }
    }
}