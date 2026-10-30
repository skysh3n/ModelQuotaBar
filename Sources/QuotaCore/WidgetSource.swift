import AppIntents
import Foundation
import WidgetKit

/// WidgetKit 的 reload。主应用与扩展都会编译本文件。
/// 刷新按钮的 `RefreshQuotaIntent` 在 `Widget/RefreshQuotaIntent.swift`，
/// **App + Widget 双 target**（`openAppWhenRun = false`），否则 macOS 上按钮不可交互。
enum WidgetReloader {
    static func reload() {
        // WidgetCenter 在扩展进程里可用。
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 小组件可显示的来源。
///
/// 放在 QuotaCore（主应用和小组件扩展都编译它），而不是只放扩展里：
/// macOS 的「编辑小组件」入口需要配置意图在主应用这一侧也能被发现。
/// 新增厂商时在这里加 case，并同步 `matches` 与 `caseDisplayRepresentations`。
enum WidgetSource: String, Codable, CaseIterable, AppEnum {
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"
    case cursor = "cursor"

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
        .cursor: DisplayRepresentation(
            title: "Cursor",
            subtitle: "订阅用量",
            image: .init(systemName: "cursorarrow.rays")),
    ]

    var displayName: String {
        switch self {
        case .qwen: "通义千问"
        case .deepseek: "DeepSeek"
        case .cursor: "Cursor"
        }
    }

    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.id == rawValue
    }

    /// 接入 Cursor 之前，小组件默认只勾了千问和 DeepSeek。
    /// 系统不会把新的默认值写回已经放在桌面上的小组件，这里按这个旧组合识别出来，补上新来源。
    static let legacyDefault: [WidgetSource] = [.qwen, .deepseek]

    /// 主界面已启用且填好凭据的来源。
    ///
    /// 关掉供应商时会删掉凭据，所以「有完整凭据」≈「主界面开着」。
    /// 小组件勾选列表只展示这些，关掉的不会出现。
    static func availableSources() -> [WidgetSource] {
        allCases.filter { source in
            guard let provider = ProviderRegistry.descriptor(for: ProviderID(source.rawValue)) else {
                return false
            }
            return CredentialStore.loadCredential(for: provider.id)
                .isComplete(for: provider.credentialFields)
        }
    }

    /// 勾选列表归一化：升级前的默认勾选补上新来源；空列表视为全部；
    /// 再去掉主界面已关掉的，避免刷新还去请求它们。
    static func effectiveDisplaySources(_ sources: [WidgetSource]) -> [WidgetSource] {
        effectiveDisplaySources(sources, available: availableSources())
    }

    /// - Parameter available: 传入时按这份列表过滤；空数组表示「不过滤」（测试 / 尚未配置）。
    static func effectiveDisplaySources(
        _ sources: [WidgetSource],
        available: [WidgetSource]
    ) -> [WidgetSource] {
        let requested: [WidgetSource]
        if sources == legacyDefault || sources.isEmpty {
            requested = Array(allCases)
        } else {
            requested = sources
        }
        guard !available.isEmpty else { return requested }
        let filtered = requested.filter { available.contains($0) }
        return filtered.isEmpty ? available : filtered
    }

    /// 按勾选的来源过滤快照，保持快照本来的顺序。
    ///
    /// 勾选的来源一个都没取到数据时，退回全部：
    /// 比如只配置了 Cursor、但小组件还是默认勾选，不能因此显示空白。
    static func select(_ sources: [WidgetSource], from snapshots: [WidgetSnapshot]) -> [WidgetSnapshot] {
        select(sources, from: snapshots, available: availableSources())
    }

    static func select(
        _ sources: [WidgetSource],
        from snapshots: [WidgetSnapshot],
        available: [WidgetSource]
    ) -> [WidgetSnapshot] {
        let effective = effectiveDisplaySources(sources, available: available)
        let selected = snapshots.filter { snapshot in
            effective.contains { $0.matches(snapshot) }
        }
        return selected.isEmpty ? snapshots : selected
    }

    /// 缓存是否已经旧到值得再抓一次。尺寸切换会重跑 timeline，这里用来跳过无谓的网络请求。
    static func needsRefresh(
        _ snapshots: [WidgetSnapshot],
        sources: [WidgetSource],
        now: Date = Date(),
        maxAge: TimeInterval = 14 * 60,
        available: [WidgetSource] = []
    ) -> Bool {
        // 默认 available 为空 = 不过滤，避免单测读到本机凭据；生产路径显式传入。
        let pool = available
        let effective = effectiveDisplaySources(sources, available: pool)
        let selected = select(sources, from: snapshots, available: pool)
        let missing = effective.contains { source in
            !snapshots.contains { source.matches($0) }
        }
        if missing { return true }
        guard let oldest = selected.map(\.updatedAt).min() else { return true }
        return now.timeIntervalSince(oldest) > maxAge
    }
}

/// 勾选列表的动态选项：只给出主界面仍启用（有凭据）的供应商。
struct AvailableWidgetSourcesProvider: DynamicOptionsProvider {
    func results() async throws -> [WidgetSource] {
        let available = WidgetSource.availableSources()
        // 一个都没配时仍列出全部，方便用户知道有哪些来源；点进去会是空数据。
        return available.isEmpty ? Array(WidgetSource.allCases) : available
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

    @Parameter(
        title: "显示来源",
        default: [.qwen, .deepseek, .cursor],
        optionsProvider: AvailableWidgetSourcesProvider())
    var sources: [WidgetSource]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
