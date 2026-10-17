import AppIntents
import SwiftUI
import WidgetKit

/// 一个小组件时间线条目。保留全部快照与「勾选了哪些来源」：
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let allSnapshots: [WidgetSnapshot]
    let sources: [WidgetSource]

    /// 按勾选的来源过滤。一个都没勾（或都被删了）时退回全部，避免显示空白。
    var selectedSnapshots: [WidgetSnapshot] {
        guard !sources.isEmpty else { return allSnapshots }
        return allSnapshots.filter { snapshot in
            sources.contains { $0.matches(snapshot) }
        }
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

/// 小组件**自己**去抓最新数据——和天气小组件同一个模式，
/// 因此不依赖主应用运行，也不依赖后台常驻。
/// 抓不到（没凭据 / 断网）就退回共享容器里已有的快照，至少不显示空白。
private func readQuotaEntry(sources: [WidgetSource]) async -> QuotaEntry {
    let fresh = await QuotaFetcher.fetchAllWidgetSnapshots()
    let snapshots: [WidgetSnapshot]
    if fresh.isEmpty {
        snapshots = SharedStore.loadSnapshots()
    } else {
        snapshots = fresh
        // 回写一份，主应用下次打开时读到的是同一个数据。
        SharedStore.save(fresh)
    }
    return QuotaEntry(date: Date(), allSnapshots: snapshots, sources: sources)
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
        context.isPreview ? .placeholder : await readQuotaEntry(sources: configuration.sources)
    }

    func timeline(for configuration: SelectSourcesIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let entry = await readQuotaEntry(sources: configuration.sources)
        return Timeline(entries: [entry], policy: quotaRefreshPolicy())
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
            WidgetRefreshButton()
        }
    }
}

/// 小组件里的刷新按钮。点一下会在扩展进程里抓一次最新数据并重绘。
private struct WidgetRefreshButton: View {
    var body: some View {
        Button(intent: RefreshQuotaIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(3)
                .contentShape(Rectangle())
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
                Spacer(minLength: 0)
                WidgetProgressBar(remainingRatio: ratio)
            } else if let balance = snapshot.balanceRemaining {
                Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("账户余额")
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
                // 太窄的话右栏看着像贴着它。
                HStack(alignment: .top, spacing: 32) {
                    ForEach(snapshots) { snapshot in
                        SourceColumn(snapshot: snapshot)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 一个来源一栏：厂商名 → 大数字 → 说明 → 底部件。
/// 底部件窗口型是进度条、余额型是更新时间，两者都占固定高度，便于多栏底边对齐。
private struct SourceColumn: View {
    let snapshot: WidgetSnapshot
    /// 数字字号。单来源时放大到 46，多栏时 30。
    var valueSize: CGFloat = 30

    private var subtitle: String {
        snapshot.primaryTitle.map { "\($0)剩余" } ?? "账户余额"
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
                .foregroundStyle(.tertiary)

            Group {
                if let ratio = snapshot.primaryRemainingRatio {
                    WidgetProgressBar(remainingRatio: ratio, height: 4)
                } else {
                    Text(widgetTimeText(snapshot.updatedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: 13, alignment: .leading)
        }
        // 内容整体在栏内垂直居中，避免顶部贴边、底部空一大块。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
                .font(.system(size: valueSize, weight: .semibold, design: .rounded))
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
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(WidgetPalette.color(remainingRatio: remainingRatio))
                    .frame(width: max(0, geometry.size.width * remainingRatio))
            }
        }
        .frame(height: height)
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