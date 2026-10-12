import Foundation

/// 主应用与小组件之间的共享存储。
///
/// 小组件跑在独立进程里，拿不到主应用的任何东西，两边只能通过一个约定位置交换数据：
/// 主应用负责抓取额度并写入，小组件只负责读取和渲染。
///
/// **共享位置是小组件的沙盒容器。** 小组件扩展必须带沙盒权限（否则系统根本不加载它），
/// 而沙盒应用只能读自己的容器；主应用则不开沙盒，可以直接往那个路径写。于是：
///
/// - 主应用（无沙盒）写 `~/Library/Containers/<小组件 id>/Data/Library/Application Support/ModelQuotaBar/`
/// - 小组件（有沙盒）读自己的容器，也就是同一个目录
///
/// 这样就不需要 App Group——App Group 是受限权限，用了就必须有 provisioning profile，
/// 也就必须登录 Apple ID，对「clone 下来自己构建」的使用者门槛太高。
public enum SharedStore {
    /// 小组件扩展的 bundle ID。在 Xcode 里改 bundle ID 时必须同步改这里，
    /// 共享目录就是从它推出来的。
    public static let widgetBundleIdentifier = "com.skysh3n.ModelQuotaBar.widget"

    private static let subdirectory = "ModelQuotaBar"
    private static let snapshotFileName = "quota-snapshot.json"
    private static let settingsFileName = "widget-settings.json"

    public static var containerURL: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(widgetBundleIdentifier)/Data/Library/Application Support",
                isDirectory: true)
        let directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private static func url(for fileName: String) -> URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    /// 共享目录是否可写。为 false 时小组件会读到空数据。
    public static var isShared: Bool {
        guard let url = containerURL else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
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