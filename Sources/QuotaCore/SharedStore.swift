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

    public static var containerURL: URL? {
        let fileManager = FileManager.default
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let resolved = resolveContainerURL(
            appSupport: appSupport,
            home: fileManager.homeDirectoryForCurrentUser)
        return ensureDirectory(resolved)
    }

    /// 按「当前跑在哪个进程里」解析共享目录。纯函数，不碰文件系统，方便测试。
    ///
    /// 这是整个共享方案里最容易踩的坑：沙盒进程的 home 目录**就是它自己的容器**，
    /// 所以 `.applicationSupportDirectory` 在两个进程里指向完全不同的位置。
    /// 如果两边都用同一套拼法，小组件会把容器路径再套一层、读到一个永远不存在的目录，
    /// 表现就是小组件一直显示「还没取到额度」。
    ///
    /// - 小组件进程（有沙盒）：`appSupport` 已经落在小组件容器里，直接用它。
    /// - 主应用进程（无沙盒）：`appSupport` 是真实的 `~/Library/Application Support`，
    ///   需要自己拼出小组件容器的路径往里写。
    static func resolveContainerURL(appSupport: URL?, home: URL) -> URL {
        let marker = "/Containers/\(widgetBundleIdentifier)/"
        let base: URL
        if let appSupport, appSupport.path.contains(marker) {
            base = appSupport
        } else {
            base = home.appendingPathComponent(
                "Library/Containers/\(widgetBundleIdentifier)/Data/Library/Application Support",
                isDirectory: true)
        }
        return base.appendingPathComponent(subdirectory, isDirectory: true)
    }

    private static func ensureDirectory(_ url: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
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

    /// 把新抓到的快照盖到缓存上再写入。只刷新部分来源时用，避免把没抓的供应商冲掉。
    public static func saveMerging(_ fresh: [WidgetSnapshot]) {
        guard !fresh.isEmpty else { return }
        save(mergeSnapshots(cached: loadSnapshots(), fresh: fresh))
    }

    /// 成功的用新值盖上去，失败的保留缓存。顺序跟 ProviderRegistry 一致。
    public static func mergeSnapshots(cached: [WidgetSnapshot], fresh: [WidgetSnapshot]) -> [WidgetSnapshot] {
        guard !fresh.isEmpty else { return cached }
        var byID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        for snapshot in fresh {
            byID[snapshot.id] = snapshot
        }
        let order = ProviderRegistry.all.map(\.id.rawValue)
        let ordered = order.compactMap { byID[$0] }
        let extras = byID.values.filter { entry in !order.contains(entry.id) }
        return ordered + extras
    }

    // MARK: - 小组件手动刷新中

    /// 小组件点刷新时写入的短暂标记。WidgetKit 视图是时间线快照，没法像主应用那样
    /// 靠 `@State` 连续转圈；intent 开始/结束各 reload 一次，用这份标记切换按钮外观。
    public enum WidgetRefreshFlag {
        private static let fileName = "widget-refreshing.json"
        /// 进程被杀时避免标记永久卡住。
        public static let maxAge: TimeInterval = 60

        struct Entry: Codable, Equatable {
            var startedAt: Date
        }

        static var defaultURL: URL? {
            SharedStore.containerURL?.appendingPathComponent(fileName)
        }

        public static func isRefreshing(now: Date = Date(), url: URL? = nil) -> Bool {
            guard let url = url ?? defaultURL,
                  let data = try? Data(contentsOf: url)
            else { return false }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let entry = try? decoder.decode(Entry.self, from: data) else { return false }
            return now.timeIntervalSince(entry.startedAt) < maxAge
        }

        public static func begin(now: Date = Date(), url: URL? = nil) {
            guard let url = url ?? defaultURL else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(Entry(startedAt: now)) else { return }
            try? data.write(to: url, options: .atomic)
        }

        public static func end(url: URL? = nil) {
            guard let url = url ?? defaultURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
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
    /// 与主界面卡片标题一致，如「DeepSeek API 余额」「Cursor 订阅用量」。
    /// 旧快照没有这个字段时，界面退回 `vendor`。
    public var title: String?
    /// 套餐档次，如「Premium」「Pro 专业版」。有值时在标题旁显示徽章。
    public var planName: String?
    /// 主窗口标题，如「每月」。纯余额型来源（DeepSeek）为 nil。
    public var primaryTitle: String?
    /// 主窗口剩余比例，0...1。纯余额型来源为 nil。
    public var primaryRemainingRatio: Double?
    /// 主窗口重置时间。
    public var primaryResetsAt: Date?
    /// 账户余额（充值型来源，如 DeepSeek）。
    public var balanceRemaining: Double?
    /// 余额币种，如「CNY」。
    public var balanceUnit: String?
    /// 其余窗口，用于中等尺寸展示。
    public var secondaryWindows: [WidgetWindow]
    /// 套餐剩余天数。
    public var remainingDays: Int?
    public var updatedAt: Date

    public init(
        id: String,
        vendor: String,
        title: String? = nil,
        planName: String?,
        primaryTitle: String?,
        primaryRemainingRatio: Double?,
        primaryResetsAt: Date?,
        balanceRemaining: Double? = nil,
        balanceUnit: String? = nil,
        secondaryWindows: [WidgetWindow],
        remainingDays: Int?,
        updatedAt: Date
    ) {
        self.id = id
        self.vendor = vendor
        self.title = title
        self.planName = planName
        self.primaryTitle = primaryTitle
        self.primaryRemainingRatio = primaryRemainingRatio
        self.primaryResetsAt = primaryResetsAt
        self.balanceRemaining = balanceRemaining
        self.balanceUnit = balanceUnit
        self.secondaryWindows = secondaryWindows
        self.remainingDays = remainingDays
        self.updatedAt = updatedAt
    }

    /// 小组件栏目标题：优先完整显示名，否则厂商名。
    public var displayTitle: String { title ?? vendor }

    /// 是否为纯余额型来源（没有时间窗口，只有钱）。
    public var isBalanceOnly: Bool {
        primaryRemainingRatio == nil && balanceRemaining != nil
    }
}

/// 币种符号。余额型来源展示金额时用。
public enum CurrencySymbol {
    public static func prefix(for unit: String) -> String {
        switch unit.uppercased() {
        case "CNY": "¥"
        case "USD": "$"
        case "EUR": "€"
        case "JPY": "¥"
        default: "\(unit) "
        }
    }

    /// 金额展示：保留两位小数，带币种符号。
    public static func format(_ value: Double, unit: String) -> String {
        "\(prefix(for: unit))\(String(format: "%.2f", value))"
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

public extension QuotaSnapshot {
    /// 转成小组件用的精简快照。
    func widgetSnapshot(
        id: ProviderID,
        vendor: String,
        title: String? = nil
    ) -> WidgetSnapshot {
        let primary = primaryWindow
        return WidgetSnapshot(
            id: id.rawValue,
            vendor: vendor,
            title: title,
            planName: planName,
            primaryTitle: primary?.title,
            primaryRemainingRatio: primary?.remainingRatio,
            primaryResetsAt: primary?.resetsAt,
            // 千问的用量包单位是 Credits，和账户余额不是一回事，不进这个字段。
            balanceRemaining: balance?.unit == "Credits" ? nil : balance?.remaining,
            balanceUnit: balance?.unit == "Credits" ? nil : balance?.unit,
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