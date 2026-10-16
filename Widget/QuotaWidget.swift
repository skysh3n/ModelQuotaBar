import AppIntents
import SwiftUI
import WidgetKit

/// 小组件要显示哪个来源。
///
/// macOS 桌面小组件是静态的，不能滑动翻页，系统只支持「长按 → 编辑」选来源。
/// 新增厂商时记得在这里加 case、display 和 `matches`，以及下方 placeholder。
enum WidgetSource: String, Codable, CaseIterable, AppEnum {
    case auto
    case qwen
    case deepseek

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "显示来源")
    static let caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .auto: "自动",
        .qwen: "通义千问",
        .deepseek: "DeepSeek",
    ]

    /// 这个来源是否命中某个快照。
    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        switch self {
        case .auto: true
        case .qwen: snapshot.id == "qwen-token-plan"
        case .deepseek: snapshot.id == "deepseek"
        }
    }

    /// 过滤出要显示的来源。
    func filtered(_ snapshots: [WidgetSnapshot]) -> [WidgetSnapshot] {
        snapshots.filter { matches($0) }
    }
}

/// 小组件的配置意图：长按 → 编辑小组件时弹出的来源选择器。
struct SelectSourceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"

    @Parameter(title: "显示来源", default: .auto)
    var source: WidgetSource

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// 一个小组件时间线条目。携带选中的来源和所有有数据的快照。
struct QuotaEntry: TimelineEntry {
    let date: Date
    let source: WidgetSource
    let snapshots: [WidgetSnapshot]

    var displayedSnapshots: [WidgetSnapshot] {
        source.filtered(snapshots)
    }
}

extension QuotaEntry {
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            source: .auto,
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

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectSourceIntent, in context: Context) async -> QuotaEntry {
        context.isPreview ? .placeholder : Self.readEntry(source: configuration.source)
    }

    func timeline(for configuration: SelectSourceIntent, in context: Context) async -> Timeline<QuotaEntry> {
        // 小组件自己不发网络请求：数据由主应用（或后台代理）抓取后写进共享容器。
        // 正常刷新靠主进程在数据变化时 reloadAllTimelines；这里给个 15 分钟兜底。
        let entry = Self.readEntry(source: configuration.source)
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private static func readEntry(source: WidgetSource) -> QuotaEntry {
        QuotaEntry(date: Date(), source: source, snapshots: SharedStore.loadSnapshots())
    }
}

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        Group {
            if entry.displayedSnapshots.isEmpty {
                EmptyWidgetView()
            } else if family == .systemMedium || family == .systemLarge {
                MediumWidgetView(snapshots: entry.displayedSnapshots)
            } else {
                SmallWidgetView(snapshot: entry.displayedSnapshots[0])
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
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectSourceIntent.self, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度")
        .description("显示大模型套餐的剩余额度与账户余额。长按可切换来源。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    static let kind = "QuotaWidget"
}