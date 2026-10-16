import Foundation

/// 小组件要显示哪个来源。
///
/// macOS 桌面小组件既不能滑动、点按，`AppIntentConfiguration` 的「编辑小组件」
/// 入口在这套系统上也反复调不出来，所以来源选择放在**主应用**里，写进共享
/// 容器供小组件读取。新增厂商时在这里加 case，并同步 `matches` 与主应用选择器。
public enum WidgetSource: String, Codable, Sendable, CaseIterable {
    case auto
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"

    public var displayName: String {
        switch self {
        case .auto: "自动"
        case .qwen: "通义千问"
        case .deepseek: "DeepSeek"
        }
    }

    public func matches(_ snapshot: WidgetSnapshot) -> Bool {
        switch self {
        case .auto: true
        case .qwen: snapshot.id == "qwen-token-plan"
        case .deepseek: snapshot.id == "deepseek"
        }
    }

    public func filtered(_ snapshots: [WidgetSnapshot]) -> [WidgetSnapshot] {
        snapshots.filter { matches($0) }
    }
}