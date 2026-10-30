import AppIntents
import SwiftUI
import WidgetKit

/// 一个小组件时间线条目。保留全部快照与「勾选了哪些来源」：
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let allSnapshots: [WidgetSnapshot]
    let sources: [WidgetSource]

    var selectedSnapshots: [WidgetSnapshot] {
        WidgetSource.select(sources, from: allSnapshots)
    }
}

extension QuotaEntry {
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            allSnapshots: [
                WidgetSnapshot(
                    id: "qwen", vendor: "通义千问", title: "通义千问 Token Plan",
                    planName: "Pro 专业版",
                    primaryTitle: "每月", primaryRemainingRatio: 0.725,
                    primaryResetsAt: Date().addingTimeInterval(12 * 86_400),
                    balanceRemaining: nil, balanceUnit: nil,
                    secondaryWindows: [], remainingDays: 29, updatedAt: Date()),
                WidgetSnapshot(
                    id: "deepseek", vendor: "DeepSeek", title: "DeepSeek API 余额",
                    planName: nil,
                    primaryTitle: nil, primaryRemainingRatio: nil,
                    primaryResetsAt: nil,
                    balanceRemaining: 110.0, balanceUnit: "CNY",
                    secondaryWindows: [], remainingDays: nil, updatedAt: Date()),
            ],
            sources: [.qwen, .deepseek])
    }
}

/// 只读共享容器里上次写好的快照。切换尺寸、编辑勾选时必须秒回，不能碰网络。
private func cachedQuotaEntry(sources: [WidgetSource]) -> QuotaEntry {
    QuotaEntry(date: Date(), allSnapshots: SharedStore.loadSnapshots(), sources: sources)
}

/// 只抓当前勾选的来源；结果盖到缓存上，未显示的供应商原样保留。
private func refreshSelectedSources(_ sources: [WidgetSource]) async -> [WidgetSnapshot] {
    let ids = Set(WidgetSource.effectiveDisplaySources(sources).map(\.rawValue))
    let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: ids)
    guard !fresh.isEmpty else { return SharedStore.loadSnapshots() }
    let merged = SharedStore.mergeSnapshots(cached: SharedStore.loadSnapshots(), fresh: fresh)
    SharedStore.save(merged)
    return merged
}

/// 请求系统约 15 分钟后再刷（实际节奏由系统决定）。
/// 必须是函数：写成常量会在进程启动时就把时间定死，之后一直是过期时间点。
private func quotaRefreshPolicy() -> TimelineReloadPolicy {
    .after(Date().addingTimeInterval(15 * 60))
}

/// 时间线 Provider。小/中尺寸共用一套取数逻辑，只是渲染时取的数量不同。
struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { .placeholder }

    func snapshot(for configuration: SelectSourcesIntent, in context: Context) async -> QuotaEntry {
        // 编辑配置 / 切换尺寸时系统优先走这里，只出缓存，别卡在网络上。
        context.isPreview ? .placeholder : cachedQuotaEntry(sources: configuration.sources)
    }

    func timeline(for configuration: SelectSourcesIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let sources = configuration.sources
        let cached = SharedStore.loadSnapshots()

        // 有缓存就立刻交卷——切换尺寸也会重跑 timeline，这里绝不能 await 网络。
        // 数据确实旧了，再在后台只刷新勾选的来源，抓完若有变化再 reload。
        if !cached.isEmpty {
            if WidgetSource.needsRefresh(
                cached,
                sources: sources,
                available: WidgetSource.availableSources())
            {
                let before = cached
                Task {
                    let merged = await refreshSelectedSources(sources)
                    if merged != before {
                        WidgetReloader.reload()
                    }
                }
            }
            return Timeline(
                entries: [QuotaEntry(date: Date(), allSnapshots: cached, sources: sources)],
                policy: quotaRefreshPolicy())
        }

        // 冷启动：没有缓存才同步等一轮（仍只抓勾选的来源）。
        let snapshots = await refreshSelectedSources(sources)
        return Timeline(
            entries: [QuotaEntry(date: Date(), allSnapshots: snapshots, sources: sources)],
            policy: quotaRefreshPolicy())
    }
}

/// 右上角刷新按钮占用的宽度；分栏宽度计算必须扣掉，不能只靠外层 padding。
private let widgetRefreshClearance: CGFloat = 44

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                // 中/大尺寸并列显示所有**勾选**的来源；小尺寸只放得下第一个。
                if family == .systemMedium || family == .systemLarge {
                    if entry.selectedSnapshots.isEmpty {
                        EmptyWidgetView()
                    } else {
                        MediumWidgetView(snapshots: entry.selectedSnapshots)
                    }
                } else if let first = entry.selectedSnapshots.first {
                    SmallWidgetView(snapshot: first)
                        .padding(.trailing, widgetRefreshClearance)
                } else {
                    EmptyWidgetView()
                }
            }
            // 不用 `.invalidatableContent()`：intent 若被取消 / 误激活主应用，
            // 系统可能永久停在 redact（灰条标题、大方块、按钮里方块），看起来像占位图。
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // AppIntent 交互不占小组件每日刷新预算。无参 intent，避免归档绑钮失败。
            WidgetRefreshButton()
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// 小组件里的刷新按钮。点一下会在扩展进程里抓一次最新数据并重绘。
///
/// 点击区拉满右上角 `widgetRefreshClearance`（44×44），比可见圆更大，减少点空。
/// 不用 `.plain`：macOS 上 plain 有时吃掉命中，点击落到小组件空白处反而会打开主应用。
/// 无 `Link` / `widgetURL` / `openURL`——只绑扩展独占、**无参数**的 `RefreshQuotaIntent`。
/// 也不用 `.invalidatableContent()`，避免加载态卡住成永久灰块。
private struct WidgetRefreshButton: View {
    var body: some View {
        Button(intent: RefreshQuotaIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.7), in: Circle())
                .frame(width: widgetRefreshClearance, height: widgetRefreshClearance)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("刷新额度")
    }
}

// MARK: - 小尺寸：只展示一个来源

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetSourceHeader(snapshot: snapshot)
            Spacer(minLength: 0)
            if let ratio = snapshot.primaryRemainingRatio {
                Text(String(format: "%.1f%%", ratio * 100))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                Text("\(snapshot.primaryTitle ?? "套餐")剩余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                WidgetProgressBar(remainingRatio: ratio)
                Spacer(minLength: 0)
                if let credits = widgetCreditsText(snapshot) {
                    Text(credits)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }
            } else if let balance = snapshot.balanceRemaining {
                Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(snapshot.balanceUnit == "USD" ? "剩余 Credits" : "账户余额")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 余额型没有进度条可压底，用更新时间填住底部，
                // 否则内容会浮在中间、下半张卡显得空。
                Text(widgetTimeText(snapshot.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // 撑满并左上对齐。余额型内容窄，VStack 固有宽度小于卡片宽度时
        // SwiftUI 会把它居中，看起来就比有进度条的千问卡片往右偏。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 有每周剩余时，再带上 Account balance 的剩余 Credits，如「$0.00 剩余」。
private func widgetCreditsText(_ snapshot: WidgetSnapshot) -> String? {
    guard snapshot.primaryRemainingRatio != nil,
          let balance = snapshot.balanceRemaining
    else { return nil }
    return "\(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? "")) 剩余"
}

/// 小组件里的更新时间文案，如「14:20 更新」。
private func widgetTimeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return "\(formatter.string(from: date)) 更新"
}

// MARK: - 中尺寸

/// 中尺寸卡片是横向的，能并排显示多个来源，所以按来源数量切布局：
/// 一个来源时铺满整张卡、数字放大；两个及以上时左右分栏。
struct MediumWidgetView: View {
    let snapshots: [WidgetSnapshot]

    var body: some View {
        if snapshots.count == 1, let only = snapshots.first {
            SourceColumn(snapshot: only, valueSize: 46)
                .padding(.trailing, widgetRefreshClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // GeometryReader 给出明确高度后，栏内 Spacer 才能把底栏压到底并对齐。
            // 可用宽度要扣掉刷新按钮占位，否则最后一栏标题/徽章会画进按钮下面。
            GeometryReader { geo in
                let spacing: CGFloat = snapshots.count > 2 ? 16 : 32
                let usableWidth = max(0, geo.size.width - widgetRefreshClearance)
                let columnWidth = max(
                    0,
                    (usableWidth - spacing * CGFloat(snapshots.count - 1))
                        / CGFloat(snapshots.count))
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(snapshots) { snapshot in
                        SourceColumn(snapshot: snapshot)
                            .frame(width: columnWidth, height: geo.size.height, alignment: .topLeading)
                    }
                    Spacer(minLength: widgetRefreshClearance)
                }
            }
        }
    }
}

/// 栏目标题。有套餐档次时显示「厂商 + 徽章」（如 Cursor Premium），
/// 避免再拼「订阅用量」把右上角刷新按钮挤叠；没有档次时用完整显示名。
private struct WidgetSourceHeader: View {
    let snapshot: WidgetSnapshot

    private var titleText: String {
        if let plan = snapshot.planName, !plan.isEmpty {
            snapshot.vendor
        } else {
            snapshot.displayTitle
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(titleText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let plan = snapshot.planName, !plan.isEmpty {
                Text(plan)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 一个来源一栏（多栏时拉满高度，底栏与右侧「$x.xx 剩余」对齐）。
/// Cursor：上半百分比+进度条，底下 Credits；
/// DeepSeek：中间放大余额，底下「账户余额 + 更新」紧挨的两行小字。
private struct SourceColumn: View {
    let snapshot: WidgetSnapshot
    /// 百分比主数字字号。单来源 46，多栏 30。
    var valueSize: CGFloat = 30
    private let barHeight: CGFloat = 5

    private var isBalanceOnly: Bool {
        snapshot.primaryRemainingRatio == nil && snapshot.balanceRemaining != nil
    }

    /// DeepSeek 余额刻意比右边百分比更大。
    private var balanceHeroSize: CGFloat {
        valueSize == 46 ? 48 : 40
    }

    var body: some View {
        Group {
            if isBalanceOnly {
                balanceColumn
            } else {
                usageColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 标题 → 大余额 +「账户余额」紧挨 → 更新时间压底（与右边 Credits 齐平）。
    private var balanceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetSourceHeader(snapshot: snapshot)

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 3) {
                if let balance = snapshot.balanceRemaining {
                    Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                        .font(.system(size: balanceHeroSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(snapshot.balanceUnit == "USD" ? "剩余 Credits" : "账户余额")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(widgetTimeText(snapshot.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// 标题(+徽章) → 百分比 + 每周剩余 + 进度条 → Credits 压底。
    private var usageColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetSourceHeader(snapshot: snapshot)

            if let ratio = snapshot.primaryRemainingRatio {
                Text(String(format: "%.1f%%", ratio * 100))
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
            }

            Text(snapshot.primaryTitle.map { "\($0)剩余" } ?? "套餐剩余")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let ratio = snapshot.primaryRemainingRatio {
                WidgetProgressBar(remainingRatio: ratio, height: barHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight)
            }

            Spacer(minLength: 0)

            // 底栏 Credits 提高布局优先级，避免中尺寸双栏高度吃紧时被 Spacer 挤没。
            if let credits = widgetCreditsText(snapshot) {
                Text(credits)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
        }
    }
}

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("还没取到额度")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("打开「大模型额度」填好配置")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - 组件

private struct WidgetProgressBar: View {
    /// 填充的是剩余比例，与文案「剩 X%」同向。
    let remainingRatio: Double
    var height: CGFloat = 5

    var body: some View {
        // 不用会抢空间的 GeometryReader 当根视图，避免把整栏撑开导致无法上下居中。
        Capsule()
            .fill(.quaternary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(WidgetPalette.color(remainingRatio: remainingRatio))
                        .frame(width: max(0, geometry.size.width * remainingRatio))
                }
            }
    }
}

private enum WidgetPalette {
    static func color(remainingRatio: Double) -> Color {
        switch remainingRatio {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .accentColor
        }
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
        .description("小尺寸显示一个来源，中尺寸并排显示多个。右键可勾选来源。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}