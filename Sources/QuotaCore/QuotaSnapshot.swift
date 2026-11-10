import Foundation

/// 一个额度窗口，例如「每 5 小时」「每周」「每月」。
///
/// 不同厂商的套餐计量方式不同：千问 Token Plan 个人版按滚动时间窗的用量百分比计量，
/// 团队版和多数海外厂商按 Credits / 请求次数计量。这里统一抽象为「一个有时间起止的窗口」
/// 加一个 0...1 的已用比例，展示层只需关心比例和重置时间。
public struct QuotaWindow: Sendable, Codable, Identifiable, Hashable {
    /// 窗口标识，同一 Provider 内唯一，例如 `5h` / `weekly` / `monthly`。
    public let id: String
    /// 展示用标题，例如「每 5 小时」。
    public let title: String
    /// 已用比例，0...1。已钳制到合法区间。
    public let usedRatio: Double
    /// 窗口重置时间。厂商未提供时为 nil。
    public let resetsAt: Date?
    /// 窗口总配额（Credits / 请求次数）。厂商只返回百分比时为 nil。
    public let totalQuota: Double?
    /// 计量单位，用于拼「已用 3,200 / 45,000 Credits」这类文案。
    public let unit: String

    /// 剩余比例，0...1。
    public var remainingRatio: Double {
        max(0, min(1, 1 - usedRatio))
    }

    public init(
        id: String,
        title: String,
        usedRatio: Double,
        resetsAt: Date? = nil,
        totalQuota: Double? = nil,
        unit: String = ""
    ) {
        self.id = id
        self.title = title
        self.usedRatio = max(0, min(1, usedRatio))
        self.resetsAt = resetsAt
        self.totalQuota = totalQuota
        self.unit = unit
    }
}

/// 账户余额。用于按量计费型厂商（充值余额）或套餐外的附加额度包。
public struct CreditBalance: Sendable, Hashable {
    public let remaining: Double
    public let total: Double?
    public let unit: String
    /// 展示用标签，例如「附加资源包」「专属资源包」。无标签时退回「用量包剩余」。
    public let label: String?
    /// 该余额/资源包的到期时间。充值型来源通常为 nil。
    ///
    /// 设为 `var` 以支持 `ResourcePackageInfo.expiresAt` 的 setter 委托修改。
    /// 这是到期时间的单一事实来源，外层 `ResourcePackageInfo.expiresAt` 只是代理。
    public var expiresAt: Date?

    public init(
        remaining: Double,
        total: Double? = nil,
        unit: String = "Credits",
        label: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.remaining = remaining
        self.total = total
        self.unit = unit
        self.label = label
        self.expiresAt = expiresAt
    }

    public var used: Double? {
        guard let total else { return nil }
        return max(0, total - remaining)
    }
}

extension CreditBalance: Codable {
    private enum CodingKeys: String, CodingKey {
        case remaining, total, unit, label, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let remaining = try container.decode(Double.self, forKey: .remaining)
        let total = try container.decodeIfPresent(Double.self, forKey: .total)
        let unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? "Credits"
        // 旧 JSON 没有 label / expiresAt 时退回 nil，保持向后兼容。
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        let expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.init(remaining: remaining, total: total, unit: unit, label: label, expiresAt: expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remaining, forKey: .remaining)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}

/// 一块资源包余额，带展示标签和可选到期时间。
///
/// Qoder CN 同时存在多种资源包（附加资源包、专属资源包），用数组表达比单值更合适。
/// 其他厂商（DeepSeek、Cursor）通常只有一块，也会放进这个数组里，由展示层统一遍历。
///
/// **到期时间单一事实来源**：`expiresAt` 完全委托给内层 `balance.expiresAt`，
/// 外层不再冗余存储，避免两处不一致。
public struct ResourcePackageInfo: Sendable, Hashable {
    public var balance: CreditBalance

    /// 到期时间。直接读取内层 balance.expiresAt，单一事实来源。
    public var expiresAt: Date? {
        get { balance.expiresAt }
        set { balance.expiresAt = newValue }
    }

    public var remaining: Double { balance.remaining }
    public var total: Double? { balance.total }
    public var unit: String { balance.unit }
    public var label: String? { balance.label }

    public init(balance: CreditBalance) {
        self.balance = balance
    }

    public init(remaining: Double, total: Double? = nil, unit: String = "Credits", label: String? = nil, expiresAt: Date? = nil) {
        self.balance = CreditBalance(remaining: remaining, total: total, unit: unit, label: label, expiresAt: expiresAt)
    }
}

// MARK: - ResourcePackageInfo Codable（手写以适配 balance.expiresAt 单一来源）

extension ResourcePackageInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case balance, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBalance = try container.decode(CreditBalance.self, forKey: .balance)
        // 兼容旧 JSON：若外层有独立的 expiresAt 且 balance 里没有，用外层的。
        let outerExpiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        if decodedBalance.expiresAt == nil, let outer = outerExpiresAt {
            var balanceWithExpiry = decodedBalance
            balanceWithExpiry.expiresAt = outer
            self.balance = balanceWithExpiry
        } else {
            self.balance = decodedBalance
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(balance, forKey: .balance)
        // 同时写出外层 expiresAt，确保旧版解码器也能读到。
        try container.encodeIfPresent(balance.expiresAt, forKey: .expiresAt)
    }
}

/// 一次拉取得到的完整额度快照。
public struct QuotaSnapshot: Sendable, Equatable {
    /// 账户标识，例如主账号 UID 或邮箱。厂商未提供时为 nil。
    public var accountLabel: String?
    /// 套餐名称，例如「Pro」「Lite」。
    public var planName: String?
    /// 套餐状态，例如「VALID」。
    public var status: String?
    /// 账户是否可继续调用（余额型来源）。套餐型来源为 nil。
    public var isAvailable: Bool?
    /// 所有额度窗口，按展示顺序排列。
    public var windows: [QuotaWindow]
    /// 所有资源包 / 充值余额，按展示顺序排列。
    ///
    /// Qoder CN 会同时存在多块（附加资源包、专属资源包）；其他厂商通常只有一块。
    /// 没有资源包时为空数组。
    public var resourcePackages: [ResourcePackageInfo]
    /// 第一块资源包余额，便于旧调用点继续以单值方式读取。
    ///
    /// 保留语义：相当于 `resourcePackages.first?.balance`。新代码请直接遍历 `resourcePackages`。
    public var balance: CreditBalance? {
        resourcePackages.first?.balance
    }
    /// 套餐到期时间。
    public var expiresAt: Date?
    /// 套餐剩余天数。厂商直接给出时优先使用，避免本地时区换算误差。
    public var remainingDays: Int?
    /// 本次数据的抓取时间。
    public var updatedAt: Date

    /// 菜单栏/小组件上显示「剩余多少」时优先采用的主窗口。
    ///
    /// 选择规则：优先月度（最能代表「这个月还剩多少」），其次每周，最后第一个窗口。
    /// 千问没有月度窗口时，5 小时窗口排在最前面，但每周更能代表真实消耗，不能被
    /// 5 小时窗口的近 100% 剩余掩盖。
    public var primaryWindow: QuotaWindow? {
        windows.first { $0.id == "monthly" }
            ?? windows.first { $0.id == "weekly" }
            ?? windows.first
    }

    /// 创建额度快照。
    ///
    /// - Parameters:
    ///   - balance: 旧式单值余额入口。DeepSeek、Cursor、Qwen 等只有一个余额的来源使用。
    ///   - resourcePackages: 新式多块资源包入口。Qoder CN 等可能有多块资源包的来源使用。
    ///
    /// **优先级**：若同时传入 `resourcePackages`（非空）和 `balance`，以 `resourcePackages` 为准，
    /// `balance` 被忽略。DEBUG 模式下会断言两者一致（若都有值），避免无声丢数据。
    /// 现有调用点要么只传一个、要么两者来自同一数据源，不会触发断言。
    public init(
        accountLabel: String? = nil,
        planName: String? = nil,
        status: String? = nil,
        isAvailable: Bool? = nil,
        windows: [QuotaWindow] = [],
        balance: CreditBalance? = nil,
        resourcePackages: [ResourcePackageInfo]? = nil,
        expiresAt: Date? = nil,
        remainingDays: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.accountLabel = accountLabel
        self.planName = planName
        self.status = status
        self.isAvailable = isAvailable
        self.windows = windows
        // 优先使用显式传入的 resourcePackages；否则把旧式的单值 balance 包成数组，
        // 保持现有调用方（DeepSeek、Cursor、Qwen）无需改动即可继续工作。
        let hasPackages = resourcePackages.map { !$0.isEmpty } ?? false
        if hasPackages {
            self.resourcePackages = resourcePackages!
        } else if let balance {
            self.resourcePackages = [ResourcePackageInfo(balance: balance)]
        } else {
            self.resourcePackages = []
        }
        // DEBUG 防护：若同时传了两者，确保一致（balance 等于 resourcePackages 的第一块）。
        // 线上不检查，避免正常路径崩溃。
        assert(
            !hasPackages || balance == nil || balance == resourcePackages?.first?.balance,
            "QuotaSnapshot init: 同时传入 balance 和 resourcePackages 但两者不一致。" +
            "请只传一个，或确保 balance == resourcePackages.first?.balance。")
        self.expiresAt = expiresAt
        self.remainingDays = remainingDays
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable（手写以兼容旧 JSON 里 balance 单值字段）

extension QuotaSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case accountLabel, planName, status, isAvailable, windows
        case balance, resourcePackages
        case expiresAt, remainingDays, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable)
        windows = try container.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        remainingDays = try container.decodeIfPresent(Int.self, forKey: .remainingDays)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // 新格式直接带 resourcePackages；旧格式只有 balance 单值，需要包成数组。
        if let packages = try container.decodeIfPresent([ResourcePackageInfo].self, forKey: .resourcePackages),
           !packages.isEmpty {
            resourcePackages = packages
        } else if let legacyBalance = try container.decodeIfPresent(CreditBalance.self, forKey: .balance) {
            resourcePackages = [ResourcePackageInfo(balance: legacyBalance)]
        } else {
            resourcePackages = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accountLabel, forKey: .accountLabel)
        try container.encodeIfPresent(planName, forKey: .planName)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(isAvailable, forKey: .isAvailable)
        try container.encode(windows, forKey: .windows)
        try container.encode(resourcePackages, forKey: .resourcePackages)
        // 同时写出 balance 字段，确保旧版本进程也能读到第一块资源包。
        try container.encodeIfPresent(balance, forKey: .balance)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(remainingDays, forKey: .remainingDays)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}