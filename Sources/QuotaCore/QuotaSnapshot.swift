import Foundation

/// 一个额度窗口，例如「每 5 小时」「每周」「每月」。
///
/// 不同厂商的套餐计量方式不同：千问 Token Plan 个人版按滚动时间窗的用量百分比计量，
/// 团队版和多数海外厂商按 Credits / 请求次数计量。这里统一抽象为「一个有时间起止的窗口」
/// 加一个 0...1 的已用比例，展示层只需关心比例和重置时间。
public struct QuotaWindow: Sendable, Identifiable, Hashable {
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

    public init(remaining: Double, total: Double? = nil, unit: String = "Credits") {
        self.remaining = remaining
        self.total = total
        self.unit = unit
    }

    public var used: Double? {
        guard let total else { return nil }
        return max(0, total - remaining)
    }
}

/// 一次拉取得到的完整额度快照。
public struct QuotaSnapshot: Sendable {
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
    /// 附加额度包 / 充值余额，没有则为 nil。
    public var balance: CreditBalance?
    /// 套餐到期时间。
    public var expiresAt: Date?
    /// 套餐剩余天数。厂商直接给出时优先使用，避免本地时区换算误差。
    public var remainingDays: Int?
    /// 本次数据的抓取时间。
    public var updatedAt: Date

    /// 菜单栏上显示「剩余多少」时优先采用的主窗口。
    ///
    /// 选择规则：优先月度（最能代表「这个月还剩多少」），其次第一个窗口。
    public var primaryWindow: QuotaWindow? {
        windows.first { $0.id == "monthly" } ?? windows.first
    }

    public init(
        accountLabel: String? = nil,
        planName: String? = nil,
        status: String? = nil,
        isAvailable: Bool? = nil,
        windows: [QuotaWindow] = [],
        balance: CreditBalance? = nil,
        expiresAt: Date? = nil,
        remainingDays: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.accountLabel = accountLabel
        self.planName = planName
        self.status = status
        self.isAvailable = isAvailable
        self.windows = windows
        self.balance = balance
        self.expiresAt = expiresAt
        self.remainingDays = remainingDays
        self.updatedAt = updatedAt
    }
}