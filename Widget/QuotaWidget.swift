import SwiftUI
import WidgetKit

/// 一个小组件时间线条目。同时保留全部快照与所选来源：
/// 小尺寸按来源过滤，中尺寸固定显示全部，所以两个都要留着。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let allSnapshots: [WidgetSnapshot]
    let source: WidgetSource

    /// 小尺寸用：按所选来源过滤。
    var filteredSnapshots: [WidgetSnapshot] {
        source.filtered(allSnapshots)
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
            source: .auto)
    }
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectSourceIntent, in context: Context) async -> QuotaEntry {
        context.isPreview ? .placeholder : await Self.readEntry(source: configuration.source)
    }

    func timeline(for configuration: SelectSourceIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let entry = await Self.readEntry(source: configuration.source)
        // 请求系统约 15 分钟后再来一次（实际节奏由系统决定）。
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// 小组件**自己**去抓最新数据——和天气小组件同一个模式，
    /// 因此不依赖主应用运行，也不依赖后台常驻。
    /// 抓不到（没凭据 / 断网）就退回共享容器里已有的快照，至少不显示空白。
    private static func readEntry(source: WidgetSource) async -> QuotaEntry {
        let fresh = await QuotaFetcher.fetchAllWidgetSnapshots()
        let snapshots: [WidgetSnapshot]
        if fresh.isEmpty {
            snapshots = SharedStore.loadSnapshots()
        } else {
            snapshots = fresh
            // 回写一份，主应用下次打开时读到的是同一个数据。
            SharedStore.save(fresh)
        }
        return QuotaEntry(date: Date(), allSnapshots: snapshots, source: source)
    }
}

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        Group {
            // 中/大尺寸空间够，固定并列显示全部来源，忽略来源选择
            // （否则用户在中尺寸上选了单一来源会看到大片空白）。
            if family == .systemMedium || family == .systemLarge {
                if entry.allSnapshots.isEmpty {
                    EmptyWidgetView()
                } else {
                    MediumWidgetView(snapshots: entry.allSnapshots)
                }
            } else if let first = entry.filteredSnapshots.first {
                SmallWidgetView(snapshot: first)
            } else {
                EmptyWidgetView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
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
                Text("\(Self.timeText(snapshot.updatedAt)) 更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // 撑满并左上对齐。余额型内容窄，VStack 固有宽度小于卡片宽度时
        // SwiftUI 会把它居中，看起来就比有进度条的千问卡片往右偏。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 中尺寸：左右两栏并列

struct MediumWidgetView: View {
    let snapshots: [WidgetSnapshot]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(snapshots) { snapshot in
                SourceColumn(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 一个来源一栏。中尺寸卡片本来就是横向的，左右分栏比上下堆叠更饱满，
/// 也能让两家的数字并排好对比。
private struct SourceColumn: View {
    let snapshot: WidgetSnapshot

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
                    Color.clear
                }
            }
            .frame(height: 4, alignment: .leading)
        }
        // 内容整体在栏内垂直居中，避免顶部贴边、底部空一大块。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var valueText: some View {
        if let ratio = snapshot.primaryRemainingRatio {
            Text(String(format: "%.1f%%", ratio * 100))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
        } else if let balance = snapshot.balanceRemaining {
            Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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

/// 可配置来源的小组件。右键 →「编辑」可切换显示哪个来源（默认全部）。
/// 想「一个千问一个 DeepSeek」就加两个实例，各自在编辑里选来源。
struct QuotaWidget: Widget {
    static let kind = "QuotaWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectSourceIntent.self, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度")
        .description("显示大模型套餐的剩余额度与余额，右键可切换来源。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}