import AppIntents
import SwiftUI
import WidgetKit

/// 一个小组件时间线条目。保留全部快照与「勾选了哪些来源」：
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let allSnapshots: [WidgetSnapshot]
    let sources: [WidgetSource]
    /// 组件库预览用的占位数据，不套「可用来源」过滤（新用户可能还没配凭据）。
    let isPlaceholder: Bool

    init(
        date: Date,
        allSnapshots: [WidgetSnapshot],
        sources: [WidgetSource],
        isPlaceholder: Bool = false
    ) {
        self.date = date
        self.allSnapshots = allSnapshots
        self.sources = sources
        self.isPlaceholder = isPlaceholder
    }

    var selectedSnapshots: [WidgetSnapshot] {
        // 主界面关掉的来源，不管是哪一个，都不画。开关还开着也不行。
        let allowed = WidgetSource.droppingDisabled(allSnapshots)
        if isPlaceholder {
            return allowed
        }
        let display = WidgetSource.widgetDisplaySources(
            toggles: sources,
            cachedIDs: Set(allowed.map(\.id)))
        let ordered = WidgetSource.orderedSnapshots(display, from: allowed)
        // 过期来源即使不在前两个勾选里，也要占一个可见位置，否则桌面上没有提示。
        return WidgetSource.promotingLoginExpired(ordered, from: allowed)
    }
}

extension QuotaEntry {
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            allSnapshots: [
                WidgetSnapshot(
                    id: "qwen-token-plan", vendor: "通义千问", title: "通义千问 Token Plan",
                    planName: "Pro 专业版",
                    primaryTitle: "每月", primaryRemainingRatio: 0.725,
                    primaryResetsAt: Date().addingTimeInterval(12 * 86_400),
                    balanceRemaining: nil, balanceUnit: nil,
                    secondaryWindows: [
                        WidgetWindow(id: "weekly", title: "每周", remainingRatio: 0.62, resetsAt: nil),
                    ],
                    remainingDays: 29, updatedAt: Date()),
                WidgetSnapshot(
                    id: "deepseek", vendor: "DeepSeek", title: "DeepSeek API 余额",
                    planName: nil,
                    primaryTitle: nil, primaryRemainingRatio: nil,
                    primaryResetsAt: nil,
                    balanceRemaining: 110.0, balanceUnit: "CNY",
                    secondaryWindows: [], remainingDays: nil, updatedAt: Date()),
            ],
            sources: [.qwen, .deepseek],
            isPlaceholder: true)
    }
}

/// 只读共享容器里上次写好的快照。切换尺寸、编辑勾选时必须秒回，不能碰网络。
private func cachedQuotaEntry(sources: [WidgetSource]) -> QuotaEntry {
    QuotaEntry(date: Date(), allSnapshots: SharedStore.loadSnapshots(), sources: sources)
}

/// 只抓主应用当前打开的来源；结果盖到缓存上。
///
/// `keeping` 是当前仍可用（已启用 + 凭据完整）的来源：停用/清空凭据的来源会从
/// 缓存里清掉，全都没有时缓存也会被清空，不会永远显示旧数据。
private func refreshEnabledSources() async -> [WidgetSnapshot] {
    let available = WidgetSource.availableSources()
    let enabled = SharedStore.loadEnabledProviderIDs()
    guard let availableIDs = WidgetSource.refreshKeepIDs(available: available, enabled: enabled) else {
        return SharedStore.loadSnapshots()
    }
    let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: availableIDs)
    return SharedStore.saveMerging(fresh, keeping: availableIDs)
}

/// 请求系统约 15 分钟后再刷（实际节奏由系统决定）。
/// 必须是函数：写成常量会在进程启动时就把时间定死，之后一直是过期时间点。
private func quotaRefreshPolicy() -> TimelineReloadPolicy {
    .after(Date().addingTimeInterval(15 * 60))
}

/// 时间线 Provider。小/中尺寸共用一套取数逻辑，只是渲染时取的数量不同。
struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        cachedQuotaEntry(sources: Array(WidgetSource.allCases))
    }

    func snapshot(for configuration: SelectSourcesIntent, in context: Context) async -> QuotaEntry {
        // 编辑面板的预览必须跟着当前勾选走，不能总画启用列表的前两个。
        cachedQuotaEntry(sources: configuration.sources)
    }

    func timeline(for configuration: SelectSourcesIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let cached = SharedStore.loadSnapshots()
        let sources = configuration.sources
        let display = WidgetSource.widgetDisplaySources(
            toggles: sources,
            cachedIDs: Set(cached.map(\.id)))

        // 有缓存就立刻交卷——切换尺寸也会重跑 timeline，这里绝不能 await 网络。
        // 数据确实旧了，再在后台只刷新主应用打开的来源，抓完若有变化再 reload。
        if !cached.isEmpty {
            if WidgetSource.needsRefresh(
                cached,
                sources: display,
                available: display)
            {
                let before = cached
                Task {
                    let merged = await refreshEnabledSources()
                    if !SharedStore.snapshotsHaveSameContent(merged, before) {
                        WidgetReloader.reload()
                    }
                }
            }
            return Timeline(
                entries: [QuotaEntry(date: Date(), allSnapshots: cached, sources: sources)],
                policy: quotaRefreshPolicy())
        }

        // 冷启动：没有缓存才同步等一轮（仍只抓主应用打开的来源）。
        let snapshots = await refreshEnabledSources()
        return Timeline(
            entries: [QuotaEntry(date: Date(), allSnapshots: snapshots, sources: sources)],
            policy: quotaRefreshPolicy())
    }
}

// MARK: - 配置

/// 一个小组件同时支持小/中尺寸，配置为**多选**来源：
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的。
struct QuotaWidget: Widget {
    static let kind = "QuotaWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: SelectSourcesIntent.self,
            provider: QuotaTimelineProvider()
        ) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度")
        .description("用开关选择来源，最多同时打开两个。主界面关掉的来源都不会画出来。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
