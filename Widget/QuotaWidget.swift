import SwiftUI
import WidgetKit

/// 一个小组件时间线条目，携带已经按来源过滤好的快照。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshots: [WidgetSnapshot]
}

extension QuotaEntry {
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            snapshots: [
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
            ])
    }
}

struct QuotaTimelineProvider: TimelineProvider {
    /// 本小组件固定显示哪个来源。
    let source: WidgetSource

    func placeholder(in context: Context) -> QuotaEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(context.isPreview ? .placeholder : Self.readEntry(source: source))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        // 小组件自己不发网络请求：数据由主应用（或后台代理）抓取后写进共享容器。
        // 正常刷新靠主进程在数据变化时 reloadAllTimelines；这里给个 15 分钟兜底。
        let entry = Self.readEntry(source: source)
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func readEntry(source: WidgetSource) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshots: source.filtered(SharedStore.loadSnapshots()))
    }
}

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        Group {
            if entry.snapshots.isEmpty {
                EmptyWidgetView()
            } else if family == .systemMedium || family == .systemLarge {
                MediumWidgetView(snapshots: entry.snapshots)
            } else {
                SmallWidgetView(snapshot: entry.snapshots[0])
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
            }
        }
    }
}

// MARK: - 中尺寸：并列列出所选来源

struct MediumWidgetView: View {
    let snapshots: [WidgetSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(snapshots) { snapshot in
                SourceRow(snapshot: snapshot)
            }
        }
    }
}

private struct SourceRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.vendor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ratio = snapshot.primaryRemainingRatio {
                    Text(String(format: "%.1f%%", ratio * 100))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                } else if let balance = snapshot.balanceRemaining {
                    Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            HStack(spacing: 6) {
                if let ratio = snapshot.primaryRemainingRatio {
                    Text("\(snapshot.primaryTitle ?? "套餐")剩余")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    WidgetProgressBar(remainingRatio: ratio, height: 3)
                } else {
                    Text("账户余额")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
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

struct QuotaWidget: Widget {
    static let kind = "QuotaWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider(source: .auto)) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度")
        .description("显示所有来源的剩余额度与余额。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuotaQwenWidget: Widget {
    static let kind = "QuotaQwenWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider(source: .qwen)) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度 · 通义千问")
        .description("显示通义千问 Token Plan 的剩余额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuotaDeepSeekWidget: Widget {
    static let kind = "QuotaDeepSeekWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider(source: .deepseek)) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度 · DeepSeek")
        .description("显示 DeepSeek 账户余额。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}