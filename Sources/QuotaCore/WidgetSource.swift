import AppIntents
import Foundation

/// 小组件可显示的来源。
///
/// 放在 QuotaCore（主应用和小组件扩展都编译它），而不是只放扩展里：
/// macOS 的「编辑小组件」入口需要配置意图在主应用这一侧也能被发现。
/// 新增厂商时在这里加 case，并同步 `matches` 与 `caseDisplayRepresentations`。
enum WidgetSource: String, Codable, CaseIterable, AppEnum {
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "显示来源")
    static let caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .qwen: DisplayRepresentation(
            title: "通义千问",
            subtitle: "Token Plan 额度",
            image: .init(systemName: "sparkles")),
        .deepseek: DisplayRepresentation(
            title: "DeepSeek",
            subtitle: "账户余额",
            image: .init(systemName: "yensign.circle")),
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

/// 小尺寸用的配置意图：**单选**。
/// 小尺寸只放得下一个来源，给多选没有意义。
struct SelectOneSourceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"
    static let description = IntentDescription("小尺寸一次只显示一个来源。")

    @Parameter(title: "显示来源", default: .qwen)
    var source: WidgetSource

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// 中尺寸用的配置意图：**多选**。
/// 中尺寸能并排显示多个来源，勾几个就显示几个，将来加厂商也不用改结构。
struct SelectSourcesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"
    static let description = IntentDescription("中尺寸会并排显示所有勾选的来源。")

    @Parameter(title: "显示来源", default: [.qwen, .deepseek])
    var sources: [WidgetSource]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
