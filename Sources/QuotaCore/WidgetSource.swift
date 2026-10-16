import AppIntents
import Foundation

/// 小组件可显示的来源。
///
/// 放在 QuotaCore（主应用和小组件扩展都编译它），而不是只放扩展里：
/// macOS 的「编辑小组件」入口需要配置意图在主应用这一侧也能被发现。
/// 新增厂商时在这里加 case，并同步 `matches`。
enum WidgetSource: String, Codable, CaseIterable, AppEnum {
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "显示来源")
    static let caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .qwen: "通义千问",
        .deepseek: "DeepSeek",
    ]

    var displayName: String {
        switch self {
        case .qwen: "通义千问"
        case .deepseek: "DeepSeek"
        }
    }

    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.id == rawValue
    }
}

/// 小组件的配置意图。
///
/// 用**多选**而不是「单个来源 + 全部」：
/// - 小尺寸只放得下一个来源，取勾选里的第一个；
/// - 中尺寸并列显示所有勾选的来源。
///
/// 配置项是按小组件类型定义的、不随尺寸变化（同一个实例可以在小/中之间随时切换），
/// 所以没法给「小尺寸一套选项、中尺寸另一套」。多选列表两种尺寸都能用。
struct SelectSourceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"

    @Parameter(title: "显示来源", default: [.qwen, .deepseek])
    var sources: [WidgetSource]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
