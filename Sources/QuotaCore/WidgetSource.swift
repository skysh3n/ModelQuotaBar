import AppIntents
import Foundation

/// 小组件显示哪个来源。
///
/// 放在 QuotaCore（主应用和小组件扩展都编译它），而不是只放扩展里：
/// macOS 的「编辑小组件」入口需要配置意图在主应用这一侧也能被发现。
/// 新增厂商时在这里加 case，并同步 `matches`。
enum WidgetSource: String, Codable, CaseIterable, AppEnum {
    case auto
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "显示来源")
    static let caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .auto: "全部",
        .qwen: "通义千问",
        .deepseek: "DeepSeek",
    ]

    var displayName: String {
        switch self {
        case .auto: "全部"
        case .qwen: "通义千问"
        case .deepseek: "DeepSeek"
        }
    }

    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        switch self {
        case .auto: true
        case .qwen: snapshot.id == "qwen-token-plan"
        case .deepseek: snapshot.id == "deepseek"
        }
    }

    func filtered(_ snapshots: [WidgetSnapshot]) -> [WidgetSnapshot] {
        snapshots.filter { matches($0) }
    }
}

/// 小组件的配置意图：右键小组件 →「编辑」时弹出的来源选择器。
struct SelectSourceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"

    @Parameter(title: "显示来源", default: .auto)
    var source: WidgetSource

    func perform() async throws -> some IntentResult {
        .result()
    }
}
