import SwiftUI

/// 额度进度条。
///
/// 填充的是**剩余**比例，和旁边的「剩 X%」文案保持同一个方向——
/// 否则会出现「写着剩 100%、条却是空的」这种自相矛盾的画面。
/// 颜色也按剩余比例走，越少越刺眼。
struct QuotaBar: View {
    let remainingRatio: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(QuotaPalette.color(remainingRatio: remainingRatio))
                    .frame(width: max(0, geometry.size.width * remainingRatio))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 一行额度窗口：名称、进度条、剩余比例、重置时间。
struct QuotaWindowRow: View {
    let window: QuotaWindow
    var isPrimary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(isPrimary ? .subheadline.weight(.semibold) : .caption)
                    .foregroundStyle(isPrimary ? .primary : .secondary)
                Spacer()
                Text("剩 \(percent(window.remainingRatio))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(QuotaPalette.color(remainingRatio: window.remainingRatio))
            }
            QuotaBar(remainingRatio: window.remainingRatio, height: isPrimary ? 7 : 5)
            HStack(spacing: 6) {
                if let total = window.totalQuota, let remaining = Format.remainingCredits(of: window) {
                    Text("\(Format.credits(remaining)) / \(Format.credits(total)) \(window.unit)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let reset = Format.relativeReset(window.resetsAt) {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        // 剩得多的时候小数没意义，剩得少的时候一位小数能看出变化。
        return value >= 99 ? "99%+" : String(format: "%.1f%%", value)
    }
}