import Foundation

/// 主应用与小组件之间的共享存储。
///
/// 小组件跑在独立进程、独立沙盒里，拿不到主应用的任何东西，两边只能通过
/// App Group 容器交换数据：主应用负责抓取额度并写入，小组件只负责读取和渲染。
///
/// 没配好 App Group 时（例如没选开发团队就本地跑），退化成各自的目录，
/// 此时主应用照常工作，小组件显示空状态——不会崩，也不会互相干扰。
public enum SharedStore {
    /// 与 Xcode 工程里两个 target 的 App Groups 能力保持一致。
    public static let appGroupID = "group.com.skysh3n.ModelQuotaBar"

    private static let snapshotFileName = "quota-snapshot.json"
    private static let settingsFileName = "widget-settings.json"

    /// 共享目录。优先 App Group 容器。
    public static var containerURL: URL? {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        {
            return url
        }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
    }

    private static func url(for fileName: String) -> URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    /// 是否真的共享成功。为 false 时说明 App Group 没生效，小组件会读到空数据。
    public static var isShared: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    // MARK: - 额度快照

    /// 写入快照，供小组件读取。
    public static func save(_ snapshots: [WidgetSnapshot]) {
        guard let url = url(for: snapshotFileName) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        // 原子写入：小组件可能正好在这一刻读，不能读到写了一半的文件。
        try? data.write(to: url, options: .atomic)
    }

    /// 读取快照。小组件侧调用。
    public static func loadSnapshots() -> [WidgetSnapshot] {
        guard let url = url(for: snapshotFileName),
              let data = try? Data(contentsOf: url)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WidgetSnapshot].self, from: data)) ?? []
    }

    // MARK: - 小组件展示设置

    /// 小组件要显示哪个来源、用哪种展示方式。
    public static func saveWidgetSettings(_ settings: WidgetSettings) {
        guard let url = url(for: settingsFileName),
              let data = try? JSONEncoder().encode(settings)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadWidgetSettings() -> WidgetSettings {
        guard let url = url(for: settingsFileName),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data)
        else { return WidgetSettings() }
        return settings
    }
}

/// 小组件渲染所需的最小数据集。
///
/// 刻意不复用 `QuotaSnapshot`：小组件进程只需要画图，带过去的数据越少越好，
/// 也避免以后改内部模型时把已安装的小组件读崩。
public struct WidgetSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// 厂商名，如「通义千问」。
    public var vendor: String
    /// 套餐名，如「Pro 专业版」。
    public var planName: String?
    /// 主窗口标题，如「每月」。
    public var primaryTitle: String
    /// 主窗口剩余比例，0...1。
    public var primaryRemainingRatio: Double
    /// 主窗口重置时间。
    public var primaryResetsAt: Date?
    /// 其余窗口，用于中等尺寸展示。
    public var secondaryWindows: [WidgetWindow]
    /// 套餐剩余天数。
    public var remainingDays: Int?
    public var updatedAt: Date

    public init(
        id: String,
        vendor: String,
        planName: String?,
        primaryTitle: String,
        primaryRemainingRatio: Double,
        primaryResetsAt: Date?,
        secondaryWindows: [WidgetWindow],
        remainingDays: Int?,
        updatedAt: Date
    ) {
        self.id = id
        self.vendor = vendor
        self.planName = planName
        self.primaryTitle = primaryTitle
        self.primaryRemainingRatio = primaryRemainingRatio
        self.primaryResetsAt = primaryResetsAt
        self.secondaryWindows = secondaryWindows
        self.remainingDays = remainingDays
        self.updatedAt = updatedAt
    }
}

public struct WidgetWindow: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var remainingRatio: Double
    public var resetsAt: Date?

    public init(id: String, title: String, remainingRatio: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.remainingRatio = remainingRatio
        self.resetsAt = resetsAt
    }
}

/// 小组件的展示偏好。
public struct WidgetSettings: Codable, Sendable, Hashable {
    public enum DisplayMode: String, Codable, Sendable, CaseIterable {
        case remainingPercent
        case usedPercent
    }

    /// 显示哪个来源的额度；nil 表示第一个。
    public var providerID: String?
    public var displayMode: DisplayMode

    public init(providerID: String? = nil, displayMode: DisplayMode = .remainingPercent) {
        self.providerID = providerID
        self.displayMode = displayMode
    }
}

public extension QuotaSnapshot {
    /// 转成小组件用的精简快照。
    func widgetSnapshot(
        id: ProviderID,
        vendor: String,
        fallbackTitle: String = "套餐"
    ) -> WidgetSnapshot {
        let primary = primaryWindow
        return WidgetSnapshot(
            id: id.rawValue,
            vendor: vendor,
            planName: planName,
            primaryTitle: primary?.title ?? fallbackTitle,
            primaryRemainingRatio: primary?.remainingRatio ?? 0,
            primaryResetsAt: primary?.resetsAt,
            secondaryWindows: windows
                .filter { $0.id != primary?.id }
                .map {
                    WidgetWindow(
                        id: $0.id,
                        title: $0.title,
                        remainingRatio: $0.remainingRatio,
                        resetsAt: $0.resetsAt)
                },
            remainingDays: remainingDays,
            updatedAt: updatedAt)
    }
}