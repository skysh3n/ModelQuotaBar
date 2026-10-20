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
                    id: "qwen", vendor: "通义千问", planName: "Pro 专业版",
                    primaryTitle: "每月", primaryRemainingRatio: 0.725,
                    primaryResetsAt: Date().addingTimeInterval(12 * 86_400),
                    balanceRemaining: nil, balanceUnit: nil,
                    secondaryWindows: [], remainingDays: 29, updatedAt: Date()),
                WidgetSnapshot(
                    id: "deepseek", vendor: "DeepSeek", planName: "API 余额",
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

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
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
            } else {
                EmptyWidgetView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // 右上角放一个刷新按钮：AppIntent 交互**不占**小组件的每日刷新预算，
        // 所以这是唯一能做到「我看它的时候点一下就立刻更新」的公开机制。
        .overlay(alignment: .topTrailing) {
            WidgetRefreshButton(sources: entry.sources)
        }
    }
}

/// 小组件里的刷新按钮。点一下会在扩展进程里抓一次最新数据并重绘。
///
/// 尺寸按可点性来定：图标 14pt、点击区 30×30，配一层淡淡的圆形底，
/// 既够手指/鼠标点，也不会在卡片里显得突兀。
private struct WidgetRefreshButton: View {
    let sources: [WidgetSource]

    var body: some View {
        // 只刷新当前勾选的来源，没显示的供应商直接跳过。
        Button(intent: RefreshQuotaIntent(sources: sources)) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.7), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新额度")
    }
}

// MARK: - 小尺寸：只展示一个来源

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.vendor)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        Group {
            if snapshots.count == 1, let only = snapshots.first {
                SourceColumn(snapshot: only, valueSize: 46)
            } else {
                // 栏间距给得比一般间距宽：左栏的进度条会一直顶到分栏线，
                // 太窄的话右栏看着像贴着它。三栏时卡片放不下这么宽的间距。
                HStack(alignment: .center, spacing: snapshots.count > 2 ? 16 : 32) {
                    ForEach(snapshots) { snapshot in
                        SourceColumn(snapshot: snapshot)
                    }
                }
            }
        }
        // 先按内容高度收紧，再在整张卡片里垂直居中（小组件里栏内 Spacer 经常不生效）。
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// 一个来源一栏：厂商名 → 大数字 → 说明 → 进度条槽 → 底栏。
/// Cursor（相对截图对调后）：每周剩余 → 进度条 →「$x.xx 剩余」；
/// 余额型在进度条槽留空，底栏放更新时间，与右边「$x.xx 剩余」齐平。
private struct SourceColumn: View {
    let snapshot: WidgetSnapshot
    /// 数字字号。单来源时放大到 46，多栏时百分比 30、纯余额再大一档。
    var valueSize: CGFloat = 30
    private let barHeight: CGFloat = 5

    /// 纯余额（如 DeepSeek 的 ¥8.47）比百分比主数字再放大一点。
    private var heroSize: CGFloat {
        snapshot.primaryRemainingRatio == nil ? valueSize + 8 : valueSize
    }

    private var subtitle: String {
        if let title = snapshot.primaryTitle {
            "\(title)剩余"
        } else if snapshot.balanceUnit == "USD" {
            "剩余 Credits"
        } else {
            "账户余额"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.vendor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            valueText

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 进度条槽：有周剩余就画条，否则留同样高度，两栏「账户余额 / 每周剩余」齐平。
            Group {
                if let ratio = snapshot.primaryRemainingRatio {
                    WidgetProgressBar(remainingRatio: ratio, height: barHeight)
                } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: barHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)

            // 底栏：Cursor Credits 放大；DeepSeek 更新时间保持小号。
            Group {
                if let credits = widgetCreditsText(snapshot) {
                    Text(credits)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(widgetTimeText(snapshot.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var valueText: some View {
        if let ratio = snapshot.primaryRemainingRatio {
            Text(String(format: "%.1f%%", ratio * 100))
                .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
        } else if let balance = snapshot.balanceRemaining {
            Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
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