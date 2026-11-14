import AppIntents
import SwiftUI
import WidgetKit

/// 右上角刷新按钮占用的宽度；分栏宽度计算必须扣掉，不能只靠外层 padding。
let widgetRefreshClearance: CGFloat = 44

/// 小尺寸底部资源包行是否用整卡宽度（只有标题行避让刷新按钮）。
///
/// 多块资源包（Qoder CN）时，「标签列 + 数值列」在扣掉 44pt 按钮避让后放不下，
/// Grid 会按每行各自的溢出量分别缩字号，标签和数值都变成上下行大小不一。
/// 这类卡片改成只让标题行避让按钮，底部行才有足够宽度把标签按 9pt、数值按 12pt 排下。
func widgetSmallRowsUseFullWidth(_ snapshot: WidgetSnapshot) -> Bool {
    snapshot.resourcePackages.count >= 2
}

/// 小尺寸底部内容离卡片底边的留白：贴着底边会被看成裁掉，而侧边留白明显更宽。
private let widgetSmallBottomLift: CGFloat = 10

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: QuotaEntry
    /// 预览宿主不是 WidgetKit 进程，`widgetFamily` 环境值取不到 small，只能显式指定。
    /// 真实小组件不传，行为不变。
    var familyOverride: WidgetFamily? = nil

    var body: some View {
        let family = familyOverride ?? environmentFamily
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
                        .padding(
                            .trailing,
                            widgetSmallRowsUseFullWidth(first) ? 0 : widgetRefreshClearance)
                } else {
                    EmptyWidgetView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // AppIntent 交互不占小组件每日刷新预算。
            WidgetRefreshButton()
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// 小组件里的刷新按钮。点一下会在扩展进程里抓一次最新数据并重绘。
///
/// 尺寸按可点性来定：图标 14pt、点击区 30×30，配一层淡淡的圆形底，
/// 既够手指/鼠标点，也不会在卡片里显得突兀。
struct WidgetRefreshButton: View {
    var body: some View {
        Button(intent: RefreshQuotaIntent()) {
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
        if snapshot.hasError, let message = snapshot.errorMessage {
            // 登录过期：显示错误提示而非额度数据
            WidgetErrorView(vendor: snapshot.displayTitle, message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.trailing, widgetRefreshClearance)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                WidgetSourceHeader(snapshot: snapshot)
                    .padding(
                        .trailing,
                        widgetSmallRowsUseFullWidth(snapshot) ? widgetRefreshClearance : 0)
                Spacer(minLength: 0)
                if let ratio = snapshot.primaryRemainingRatio {
                Text(widgetPercent(ratio))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                Text("\(snapshot.primaryTitle ?? "套餐")剩余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                WidgetProgressBar(remainingRatio: ratio)
                    .padding(.vertical, 1)
                // 「剩 X / 共 Y Credits」明细行：小尺寸也要显示，用户点名的关键信息
                if let quota = widgetQuotaText(snapshot) {
                    Text(quota)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(widgetUsageFooter(snapshot))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                // 小尺寸空间有限：多块资源包时只显示合计，单块或余额型显示详情
                if snapshot.hasAnyBalance {
                    WidgetCreditsBlock(snapshot: snapshot, valueSize: 18)
                        .layoutPriority(1)
                        // 紧凑行的标签格是可变宽度，会把整行剩余宽度全吃掉，数值列被挤窄后
                        // 每行按各自溢出量缩字号（「100」正常、「1,633」偏小）。按理想宽度排
                        // 就不抢数值列，两行数值同为 12pt。
                        .fixedSize(
                            horizontal: widgetSmallRowsUseFullWidth(snapshot), vertical: false)
                        .padding(
                            .bottom,
                            widgetSmallRowsUseFullWidth(snapshot) ? widgetSmallBottomLift : 0)
                }
            } else if snapshot.hasAnyBalance {
                // 纯余额型（如 DeepSeek）
                if let firstPackage = snapshot.resourcePackages.first {
                    Text(widgetBalanceValue(firstPackage.remaining, unit: firstPackage.unit))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(firstPackage.label ?? widgetBalanceLabel(firstPackage.unit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let balance = snapshot.balanceRemaining {
                    Text(widgetBalanceValue(balance, unit: snapshot.balanceUnit))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(widgetBalanceLabel(snapshot.balanceUnit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // 余额型也要显示「剩 X / 共 Y」明细行（用户点名的信息）
                if let quota = widgetQuotaText(snapshot) {
                    Text(quota)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 2)
                }
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
}

/// 是否是用量包（Credits），而不是充值余额（CNY/USD）。
private func widgetIsCreditsUnit(_ unit: String?) -> Bool {
    unit?.caseInsensitiveCompare("Credits") == .orderedSame
}

/// Credits 数量按整数展示，带千分位（「1,166」）。
private func widgetCount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)))
}

/// 余额数字：用量包按整数展示（「300 Credits」），金额保留两位小数。
private func widgetBalanceValue(_ value: Double, unit: String?) -> String {
    if widgetIsCreditsUnit(unit) {
        return "\(widgetCount(value)) Credits"
    }
    return CurrencySymbol.format(value, unit: unit ?? "")
}

private func widgetBalanceLabel(_ unit: String?) -> String {
    if widgetIsCreditsUnit(unit) { return "用量包剩余" }
    return unit == "USD" ? "剩余 Credits" : "账户余额"
}

/// 主窗口的「总量 / 剩余」，如「剩 1,174 / 共 2,000 Credits」。
/// 厂商只回百分比（没有总量）时返回 nil，不硬凑数字。
private func widgetQuotaText(_ snapshot: WidgetSnapshot) -> String? {
    guard let ratio = snapshot.primaryRemainingRatio,
          let total = snapshot.primaryTotalQuota, total > 0,
          let unit = snapshot.primaryUnit, !unit.isEmpty
    else { return nil }
    return "剩 \(widgetCount(total * ratio)) / 共 \(widgetCount(total)) \(unit)"
}

/// 有主窗口时压到底部的余额。
///
/// Credits 是用量包（千问、Qoder），和主窗口百分比不是一回事，单独起一行标签；
/// 金额型（Cursor）保持「$0.00 剩余」的紧凑写法。
/// 多块资源包时全部用紧凑行（标签 + 数值），避免首块大字、后续小字的不一致观感，
/// 也让底栏高度可控、页脚不被截断。
private struct WidgetCreditsBlock: View {
    let snapshot: WidgetSnapshot
    var valueSize: CGFloat = 18

    /// 多块资源包时切换到紧凑模式：每块一行，标签约 9pt、数值约 12pt。
    private var isCompactMode: Bool {
        snapshot.resourcePackages.count >= 2
    }

    var body: some View {
        if let firstPackage = snapshot.resourcePackages.first {
            if isCompactMode {
                // 紧凑模式：两列对齐 Grid，所有资源包统一样式。
                compactPackageRows
            } else if widgetIsCreditsUnit(firstPackage.unit) {
                // 单块 Credits：保持原有大字号 hero 风格。
                VStack(alignment: .leading, spacing: 1) {
                    Text(firstPackage.label ?? widgetBalanceLabel(firstPackage.unit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(widgetBalanceValue(firstPackage.remaining, unit: firstPackage.unit))
                        .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                // 单块非 Credits（如 Cursor 金额型）：紧凑写法。
                Text("\(widgetBalanceValue(firstPackage.remaining, unit: firstPackage.unit)) 剩余")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else if let balance = snapshot.balanceRemaining {
            // 兼容旧数据：没有 resourcePackages 时退回 balanceRemaining。
            if widgetIsCreditsUnit(snapshot.balanceUnit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(widgetBalanceLabel(snapshot.balanceUnit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(widgetBalanceValue(balance, unit: snapshot.balanceUnit))
                        .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("\(widgetBalanceValue(balance, unit: snapshot.balanceUnit)) 剩余")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// 紧凑行：两列对齐结构（Grid），标签一列、数值一列，两块包的数值上下对齐。
    /// 标签 lineLimit(1) + minimumScaleFactor 保证不折行、不省略；
    /// 窄上下文下去掉「Credits」单位后缀，只显示数字。
    private var compactPackageRows: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 2) {
            ForEach(Array(snapshot.resourcePackages.enumerated()), id: \.offset) { _, package in
                GridRow {
                    Text(package.label ?? widgetBalanceLabel(package.unit))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(compactBalanceValue(package.remaining, unit: package.unit))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    /// 窄上下文下的余额数值：去掉「Credits」单位后缀，只显示数字 + monospacedDigit 对齐。
    private func compactBalanceValue(_ value: Double, unit: String?) -> String {
        if widgetIsCreditsUnit(unit) {
            return widgetCount(value)
        }
        return CurrencySymbol.format(value, unit: unit ?? "")
    }
}

/// 其余窗口压成一行，例如「每周 72.5% · 每月 80.0%」。
private func widgetSecondaryText(_ snapshot: WidgetSnapshot) -> String? {
    guard !snapshot.secondaryWindows.isEmpty else { return nil }
    return snapshot.secondaryWindows
        .map { "\($0.title) \(widgetPercent($0.remainingRatio))" }
        .joined(separator: " · ")
}

/// 用量型底栏：套餐剩余天数 / 重置时间 / 更新时间。信息按需拼接，不占太多行。
private func widgetUsageFooter(_ snapshot: WidgetSnapshot) -> String {
    var parts: [String] = []
    if let days = snapshot.remainingDays {
        parts.append("套餐剩 \(days) 天")
    }
    if let reset = snapshot.primaryResetsAt, let text = widgetResetText(reset) {
        parts.append(text)
    }
    parts.append(widgetTimeText(snapshot.updatedAt))
    return parts.joined(separator: " · ")
}

/// 降级版 footer：去掉「套餐剩 X 天」，只保留重置时间 + 更新时间。
/// 用于窄上下文（小尺寸、双栏中尺寸）空间不够时。
private func widgetUsageFooterDegraded(_ snapshot: WidgetSnapshot) -> String {
    var parts: [String] = []
    if let reset = snapshot.primaryResetsAt, let text = widgetResetText(reset) {
        parts.append(text)
    }
    parts.append(widgetTimeText(snapshot.updatedAt))
    return parts.joined(separator: " · ")
}

private func widgetPercent(_ ratio: Double) -> String {
    String(format: "%.1f%%", ratio * 100)
}

private let widgetResetFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return formatter
}()

private let widgetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private func widgetResetText(_ date: Date, now: Date = Date()) -> String? {
    guard date > now else { return "即将重置" }
    return widgetResetFormatter.localizedString(for: date, relativeTo: now) + "重置"
}

/// 小组件里的更新时间文案，如「14:20 更新」。
private func widgetTimeText(_ date: Date) -> String {
    "\(widgetTimeFormatter.string(from: date)) 更新"
}

// MARK: - 中尺寸

/// 中尺寸卡片是横向的，能并排显示多个来源，所以按来源数量切布局：
/// 一个来源时铺满整张卡、数字放大；两个及以上时左右分栏。
struct MediumWidgetView: View {
    let snapshots: [WidgetSnapshot]

    var body: some View {
        if snapshots.count == 1, let only = snapshots.first {
            // 单来源中尺寸：采用更美观的空间布局
            SingleSourceMediumView(snapshot: only)
                .padding(.trailing, widgetRefreshClearance)
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

/// 单来源中尺寸的专用美化布局。
/// Qoder 单来源时：
/// - 上区：超大百分比 + 同色进度条
/// - 下区：横向并列所有资源包（各带标签）与更新时间（填满宽度）
private struct SingleSourceMediumView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if snapshot.hasError {
            WidgetErrorView(
                vendor: snapshot.displayTitle,
                message: snapshot.errorMessage ?? WidgetSnapshot.loginExpiredMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            quotaBody
        }
    }

    private var quotaBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行
            WidgetSourceHeader(snapshot: snapshot)

            if snapshot.isBalanceOnly {
                // 纯余额型（如 DeepSeek）：居中大数字
                Spacer(minLength: 2)
                if let balance = snapshot.balanceRemaining {
                    Text(widgetBalanceValue(balance, unit: snapshot.balanceUnit))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.primary)
                }
                Text(widgetBalanceLabel(snapshot.balanceUnit))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // 「剩 X / 共 Y Credits」明细行：余额型也要显示，用户点名的关键信息
                if let quota = widgetQuotaText(snapshot) {
                    Text(quota)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 2)
                }
                Spacer(minLength: 4)
            } else {
                // 百分比型（Qoder、Cursor）：大数字 + 进度条
                if let ratio = snapshot.primaryRemainingRatio {
                    Text(widgetPercent(ratio))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
                }

                if let ratio = snapshot.primaryRemainingRatio {
                    WidgetProgressBar(remainingRatio: ratio, height: 6)
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                }

                // 「剩 X / 共 Y Credits」明细行：始终显示，只缩字号不消失。
                // 这是用户点名的关键信息，任何降级路径都不能删除。
                if let quota = widgetQuotaText(snapshot) {
                    Text(quota)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }

            Spacer(minLength: 2)

            // 底部横向并列：所有资源包 + 更新时间
            HStack(alignment: .center, spacing: 12) {
                if !snapshot.isBalanceOnly {
                    // 多块资源包时并列显示，每块用自己的标签
                    WidgetResourcePackagesRow(packages: snapshot.resourcePackages)
                }

                Spacer()

                Text(widgetTimeText(snapshot.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 8)
    }
}

/// 小组件里并列显示多块资源包。
///
/// 每块资源包显示标签 + 剩余值。空间有限时只放得下 2 块，多余的合并到「合计」。
private struct WidgetResourcePackagesRow: View {
    let packages: [WidgetResourcePackage]

    var body: some View {
        if packages.isEmpty {
            // 兼容旧数据：没有 resourcePackages 时退回 balanceRemaining（由调用方处理）
            EmptyView()
        } else if packages.count == 1, let only = packages.first {
            singlePackageView(only)
        } else {
            // 多块包：横向并列，每块显示标签 + 数值
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(Array(packages.enumerated()), id: \.offset) { _, package in
                    singlePackageView(package)
                }
            }
        }
    }

    private func singlePackageView(_ package: WidgetResourcePackage) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(package.label ?? widgetBalanceLabel(package.unit))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(widgetBalanceValue(package.remaining, unit: package.unit))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .layoutPriority(1)
            if let plan = snapshot.planName, !plan.isEmpty {
                Text(plan)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 一个来源一栏（多栏时拉满高度，底栏与右侧「$x.xx 剩余」对齐）。
/// Cursor：上半百分比+进度条，底下 Credits + 重置/更新时间；
/// DeepSeek：中间放大余额，底下「账户余额 + 更新」紧挨的两行小字。
private struct SourceColumn: View {
    let snapshot: WidgetSnapshot
    /// 百分比主数字字号。单来源 46，多栏 30。
    var valueSize: CGFloat = 30
    private let barHeight: CGFloat = 5

    private var isBalanceOnly: Bool {
        snapshot.primaryRemainingRatio == nil && snapshot.hasAnyBalance
    }

    /// DeepSeek 余额刻意比右边百分比更大。
    private var balanceHeroSize: CGFloat {
        valueSize == 46 ? 48 : 40
    }

    var body: some View {
        if snapshot.hasError, let message = snapshot.errorMessage {
            // 登录过期：显示错误提示而非额度数据
            WidgetErrorView(vendor: snapshot.displayTitle, message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Group {
                if isBalanceOnly {
                    balanceColumn
                } else {
                    usageColumn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 标题 → 大余额 +「账户余额」紧挨 → 更新时间压底（与右边 Credits 齐平）。
    private var balanceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetSourceHeader(snapshot: snapshot)

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 3) {
                if let firstPackage = snapshot.resourcePackages.first {
                    Text(widgetBalanceValue(firstPackage.remaining, unit: firstPackage.unit))
                        .font(.system(size: balanceHeroSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(firstPackage.label ?? widgetBalanceLabel(firstPackage.unit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let balance = snapshot.balanceRemaining {
                    Text(widgetBalanceValue(balance, unit: snapshot.balanceUnit))
                        .font(.system(size: balanceHeroSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(widgetBalanceLabel(snapshot.balanceUnit))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 余额型也要显示「剩 X / 共 Y」明细行（用户点名的信息）
                if let quota = widgetQuotaText(snapshot) {
                    Text(quota)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 4)

            Text(widgetTimeText(snapshot.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// 标题(+徽章) → 百分比 + 周期剩余 + 进度条 → 其余窗口 → Credits/底栏。
    ///
    /// 用 ViewThatFits 给出由富到简的两个变体，SwiftUI 自动选第一个放得下的。
    /// 所有变体都保留「剩 X / 共 Y」明细行（用户点名的信息），只能缩字号不能消失。
    /// 降级优先级：周期标题 → 资源包压缩 → footer 精简。
    private var usageColumn: some View {
        ViewThatFits(in: .vertical) {
            usageColumnVariantA  // 完整布局（含周期标题）
            usageColumnVariantB  // 去掉周期标题行，明细行保留
        }
    }

    /// 变体 A：完整布局（标题、百分比、周期标题、进度条、剩/共明细、资源包、footer）。
    private var usageColumnVariantA: some View {
        usageColumnCore(showPeriodTitle: true)
    }

    /// 变体 B：去掉单独的周期标题行（如「每月剩余」），周期信息并进明细行。
    /// 「剩 X / 共 Y Credits」明细行必须保留，只缩字号不消失。
    private var usageColumnVariantB: some View {
        usageColumnCore(showPeriodTitle: false)
    }

    /// 核心布局，通过参数控制是否显示周期标题行。
    /// 「剩 X / 共 Y」明细行始终显示，只通过 minimumScaleFactor 缩小字号。
    private func usageColumnCore(showPeriodTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetSourceHeader(snapshot: snapshot)

            if let ratio = snapshot.primaryRemainingRatio {
                Text(widgetPercent(ratio))
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.color(remainingRatio: ratio))
            }

            if showPeriodTitle {
                Text(snapshot.primaryTitle.map { "\($0)剩余" } ?? "套餐剩余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let ratio = snapshot.primaryRemainingRatio {
                WidgetProgressBar(remainingRatio: ratio, height: barHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight)
            }

            // 「剩 X / 共 Y Credits」明细行：始终显示，只缩字号不消失。
            // 这是用户点名的关键信息，任何降级路径都不能删除。
            if let quota = widgetQuotaText(snapshot) {
                Text(quota)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if let secondary = widgetSecondaryText(snapshot) {
                Text(secondary)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            // 底栏余额提高布局优先级，避免中尺寸双栏高度吃紧时被 Spacer 挤没。
            if snapshot.hasAnyBalance {
                WidgetCreditsBlock(snapshot: snapshot, valueSize: 20)
                    .layoutPriority(1)
            }

            // Footer 用 ViewThatFits 保证单行：优先完整文案，空间不够时去掉「套餐剩 X 天」。
            // 绝不允许折行后被底边裁切。
            ViewThatFits(in: .horizontal) {
                Text(widgetUsageFooter(snapshot))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(widgetUsageFooterDegraded(snapshot))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .layoutPriority(1)
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

/// 登录过期错误提示视图。
struct WidgetErrorView: View {
    let vendor: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题
            Text(vendor)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // 警告图标 + 错误文案
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                Text("登录已过期")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

