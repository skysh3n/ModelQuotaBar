import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let settings: WidgetSettings
}

extension QuotaEntry {
    /// 小组件画廊里的占位预览。
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                id: "preview",
                vendor: "通义千问",
                planName: "Pro 专业版",
                primaryTitle: "每月",
                primaryRemainingRatio: 0.725,
                primaryResetsAt: Date().addingTimeInterval(12 * 86_400),
                secondaryWindows: [
                    WidgetWindow(id: "5h", title: "每 5 小时", remainingRatio: 0.999, resetsAt: nil),
                    WidgetWindow(id: "weekly", title: "每周", remainingRatio: 0.97, resetsAt: nil),
                ],
                remainingDays: 29,
                updatedAt: Date()),
            settings: WidgetSettings())
    }
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(context.isPreview ? .placeholder : Self.readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        // 小组件自己不发网络请求：数据由主应用抓取后写进共享容器，这里只读。
        // 主应用每次刷新后会调用 reloadAllTimelines()，所以这个兜底间隔可以放长，
        // 免得白白消耗系统的刷新预算。
        let entry = Self.readEntry()
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func readEntry() -> QuotaEntry {
        let settings = SharedStore.loadWidgetSettings()
        let snapshots = SharedStore.loadSnapshots()
        let selected = settings.providerID
            .flatMap { id in snapshots.first { $0.id == id } }
            ?? snapshots.first
        return QuotaEntry(date: Date(), snapshot: selected, settings: settings)
    }
}

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium, .systemLarge:
                    MediumWidgetView(snapshot: snapshot, mode: entry.settings.displayMode)
                default:
                    SmallWidgetView(snapshot: snapshot, mode: entry.settings.displayMode)
                }
            } else {
                EmptyWidgetView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - 小尺寸

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot
    let mode: WidgetSettings.DisplayMode

    private func displayRatio(_ ratio: Double) -> Double {
        mode == .remainingPercent ? ratio : 1 - ratio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.vendor)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let ratio = snapshot.primaryRemainingRatio {
                Text(String(format: "%.1f%%", displayRatio(ratio) * 100))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                Text("\(snapshot.primaryTitle ?? "套餐")\(mode == .remainingPercent ? "剩余" : "已用")")
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

// MARK: - 中 / 大尺寸

struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot
    let mode: WidgetSettings.DisplayMode

    private func displayRatio(_ ratio: Double) -> Double {
        mode == .remainingPercent ? ratio : 1 - ratio
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // 左半边：主窗口（或余额），和小尺寸保持同一套视觉。
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.vendor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let plan = snapshot.planName {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
                if let ratio = snapshot.primaryRemainingRatio {
                    Text(String(format: "%.1f%%", displayRatio(ratio) * 100))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                    Text("\(snapshot.primaryTitle ?? "套餐")\(mode == .remainingPercent ? "剩余" : "已用")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WidgetProgressBar(remainingRatio: ratio)
                } else if let balance = snapshot.balanceRemaining {
                    Text(CurrencySymbol.format(balance, unit: snapshot.balanceUnit ?? ""))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("账户余额")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右半边：其余时间窗 + 套餐有效期 / 更新时间。
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.secondaryWindows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", window.remainingRatio * 100))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        WidgetProgressBar(remainingRatio: window.remainingRatio, height: 3)
                    }
                }
                Spacer(minLength: 0)
                if let days = snapshot.remainingDays {
                    Text("套餐剩余 \(days) 天")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if snapshot.isBalanceOnly {
                    Text("实时余额")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("大模型额度")
        .description("显示大模型套餐的剩余额度与重置时间。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    static let kind = "QuotaWidget"
}