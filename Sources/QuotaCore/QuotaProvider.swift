import Foundation

/// Provider 的唯一标识。
public struct ProviderID: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 设置界面自动生成表单所需的一项凭据字段。
public struct CredentialField: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// 普通单行输入。
        case text
        /// 需要遮挡显示的敏感输入（Cookie、密钥等）。
        case secret
        /// 下拉选择。
        case picker(options: [Option])
    }

    public struct Option: Sendable, Identifiable, Hashable {
        public let id: String
        public let title: String
        public let detail: String?

        public init(id: String, title: String, detail: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    /// 存储用的键名。同时作为 `ProviderCredential` 字典的键。
    public let id: String
    public let title: String
    public let hint: String?
    public let kind: Kind
    public let isOptional: Bool
    public let defaultValue: String?

    public init(
        id: String,
        title: String,
        hint: String? = nil,
        kind: Kind = .text,
        isOptional: Bool = false,
        defaultValue: String? = nil
    ) {
        self.id = id
        self.title = title
        self.hint = hint
        self.kind = kind
        self.isOptional = isOptional
        self.defaultValue = defaultValue
    }
}

/// 用户在设置里填写的凭据，按字段 id 索引。
public struct ProviderCredential: Sendable, Hashable {
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(_ key: String) -> String? {
        get {
            guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return value
        }
        set { values[key] = newValue }
    }

    /// 是否所有必填字段都已填写。
    public func isComplete(for fields: [CredentialField]) -> Bool {
        fields.allSatisfy { field in
            field.isOptional || self[field.id] != nil
        }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// 底层键值对，用于持久化。空串会被规范化为 nil。
    public var allValues: [String: String] {
        values.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// Provider 的静态元数据，用于列表展示与设置界面。
public struct ProviderMetadata: Sendable {
    public let id: ProviderID
    /// 厂商名，例如「通义千问」。
    public let vendor: String
    /// 套餐名，例如「Token Plan」。
    public let plan: String
    /// 一句话说明这个 Provider 查询的是什么。
    public let summary: String
    /// 控制台地址，设置界面里的「打开」按钮指向它。
    public let consoleURL: URL?
    /// 控制台用量页的具体路径说明，帮助用户找到要复制的 Cookie / 密钥。
    public let consoleHint: String?

    public init(
        id: ProviderID,
        vendor: String,
        plan: String,
        summary: String,
        consoleURL: URL? = nil,
        consoleHint: String? = nil
    ) {
        self.id = id
        self.vendor = vendor
        self.plan = plan
        self.summary = summary
        self.consoleURL = consoleURL
        self.consoleHint = consoleHint
    }

    public var displayName: String { "\(vendor) \(plan)" }
}

/// 所有额度来源都要实现的协议。
///
/// 新增一个厂商只需三步：实现本协议、在 `ProviderRegistry` 里注册、补一个测试。
/// 设置界面会根据 `credentialFields` 自动生成表单，无需改动 UI 代码。
public protocol QuotaProvider: Sendable {
    /// 静态元数据。为避免创建实例即可展示，声明为类型属性。
    static var metadata: ProviderMetadata { get }

    /// 需要用户填写的凭据字段。第一个字段通常作为「主凭据」。
    static var credentialFields: [CredentialField] { get }

    /// 拉取一次额度快照。
    /// - Throws: `QuotaError`
    static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot
}

/// Provider 的值类型描述。
///
/// 相比直接传 `any QuotaProvider.Type`（existential metatype），值类型更容易存放、
/// 比较和伪造，也让 SwiftUI 的 `ForEach` 不必处理元类型（那会触发编译器崩溃）。
public struct ProviderDescriptor: Sendable, Identifiable {
    public let metadata: ProviderMetadata
    public let credentialFields: [CredentialField]
    private let fetch: @Sendable (ProviderCredential) async throws -> QuotaSnapshot

    public var id: ProviderID { metadata.id }

    public init(
        metadata: ProviderMetadata,
        credentialFields: [CredentialField],
        fetch: @escaping @Sendable (ProviderCredential) async throws -> QuotaSnapshot
    ) {
        self.metadata = metadata
        self.credentialFields = credentialFields
        self.fetch = fetch
    }

    public func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
        try await fetch(credential)
    }
}

public extension QuotaProvider {
    /// 由协议实现自动生成的描述符。
    static var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            metadata: metadata,
            credentialFields: credentialFields) { credential in
            try await Self.fetchSnapshot(credential: credential)
        }
    }
}

/// 额度相关的错误。文案面向最终用户，尽量说明「下一步该做什么」。
public enum QuotaError: LocalizedError, Sendable, Equatable {
    /// 必填凭据缺失。
    case missingCredential(String)
    /// 会话已失效，需要重新登录并更新 Cookie。
    case sessionExpired
    /// 凭据被拒绝（权限不足或密钥错误）。
    case invalidCredential(String)
    /// 网络层失败。
    case network(String)
    /// 响应无法解析。
    case decoding(String)
    /// 网关返回的业务错误。
    case api(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCredential(field):
            "请先在设置中填写「\(field)」。"
        case .sessionExpired:
            "登录会话已失效。"
        case let .invalidCredential(reason):
            "凭据无效：\(reason)"
        case let .network(reason):
            "网络请求失败：\(reason)"
        case let .decoding(reason):
            "无法解析服务端返回：\(reason)"
        case let .api(message):
            "服务端返回错误：\(message)"
        }
    }
}