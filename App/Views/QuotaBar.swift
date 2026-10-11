import SwiftUI

/// 额度进度条。按「剩余比例」着色，越少越刺眼。
struct QuotaBar: View {
    let usedRatio: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(QuotaPalette.color(remainingRatio: 1 - usedRatio))
                    .frame(width: max(0, geometry.size.width * usedRatio))
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
            QuotaBar(usedRatio: window.usedRatio, height: isPrimary ? 7 : 5)
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