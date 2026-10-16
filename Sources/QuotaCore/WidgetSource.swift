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

/// 小组件的配置意图：**多选**来源。
///
/// 配置项绑定在「小组件类型」上、拿不到尺寸信息，所以做不到「小尺寸单选、中尺寸多选」
/// 那种随尺寸变化的选项（试过拆成两个小组件类型，但组件库是按 App 分组的，
/// 拆开也看不出来，反而多一层）。统一用一个多选列表：
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的。
struct SelectSourcesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"
    static let description = IntentDescription("小尺寸显示勾选的第一个来源，中尺寸并排显示全部勾选的来源。")

    @Parameter(title: "显示来源", default: [.qwen, .deepseek])
    var sources: [WidgetSource]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
