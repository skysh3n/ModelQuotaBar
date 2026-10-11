import Foundation
import SwiftUI

/// 额度数字与时间的展示格式。
enum Format {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// 把 Credits 数量格式化成 `45,000`。
    static func credits(_ value: Double) -> String {
        decimal.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    /// 把一个窗口的剩余 Credits 算出来；缺少总量时返回 nil。
    static func remainingCredits(of window: QuotaWindow) -> Double? {
        guard let total = window.totalQuota else { return nil }
        return total * window.remainingRatio
    }

    /// `3 小时后重置` 这类相对时间。
    static func relativeReset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if date <= now { return "即将重置" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        // 格式化结果本身已经带了「后」（如「3小时后」），这里只补动词。
        return formatter.localizedString(for: date, relativeTo: now) + "重置"
    }

    /// `2026年10月11日 21:30` 这类绝对时间，用于「上次更新」。
    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

/// 剩余额度对应的警示色。
enum QuotaPalette {
    static func color(remainingRatio: Double) -> Color {
        switch remainingRatio {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .accentColor
        }
    }
}