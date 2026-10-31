import AppIntents
import Foundation
import WidgetKit

/// 小组件里那个刷新按钮背后的意图。
///
/// WidgetKit 不提供「小组件被看到」的回调，所以没法做到「一被观察就自动刷新」。
/// 系统支持的做法是交互式小组件：放置一个按钮，用户点它时在扩展进程里执行这个
/// intent——正好就是「我看它的时候让它刷新」。
struct RefreshQuotaIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新额度"
    /// 必须为 false：否则系统会为了跑 intent 激活/打开主应用，桌面小组件点刷新就会弹主界面。
    static var openAppWhenRun: Bool { false }

    /// 当前小组件勾选的来源。没带时退回默认的三个。
    @Parameter(title: "显示来源", default: [.qwen, .deepseek, .cursor])
    var sources: [WidgetSource]

    init() {}

    init(sources: [WidgetSource]) {
        self.init()
        self.sources = sources
    }

    func perform() async throws -> some IntentResult {
        let available = WidgetSource.availableSources()
        let ids = Set(WidgetSource.effectiveDisplaySources(sources, available: available).map(\.rawValue))
        let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: ids)
        // 只保留仍可用（已启用 + 凭据完整）的来源；一个都没有时连缓存一起清掉。
        SharedStore.saveMerging(fresh, keeping: Set(available.map(\.rawValue)))
        WidgetReloader.reload()
        return .result()
    }
}

/// WidgetKit 的 reload 只在本文件里用，单独包一层避免核心逻辑依赖 WidgetKit API 的细节。
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

    /// 主界面已启用且填好凭据的来源。
    ///
    /// 启用列表由主应用镜像到共享目录；共享文件不存在（旧版本）时退回「看凭据」。
    /// 两个条件都满足才可用：启用但没填凭据的抓不到数据，有凭据但被关掉的也不该出现。
    static func availableSources() -> [WidgetSource] {
        let enabled = SharedStore.loadEnabledProviderIDs().map(Set.init)
        let configured = Set(ProviderRegistry.all
            .filter { CredentialStore.loadCredential(for: $0.id).isComplete(for: $0.credentialFields) }
            .map(\.id.rawValue))
        return availableSources(enabled: enabled, configured: configured)
    }

    /// 纯函数，便于测试。
    static func availableSources(
        enabled: Set<String>?,
        configured: Set<String>
    ) -> [WidgetSource] {
        allCases.filter { source in
            guard configured.contains(source.rawValue) else { return false }
            if let enabled {
                return enabled.contains(source.rawValue)
            }
            return true
        }
    }

    /// 勾选列表过滤：只保留仍可用的来源。
    ///
    /// 不会再把「勾选为空 / 勾选来源都不可用」兜底成全部来源——那会让用户
    /// 取消勾选后反而看到所有来源，也让「只勾千问+DeepSeek」永远藏不掉 Cursor。
    /// 没有可用来源时界面显示空状态，由用户去配置。
    static func effectiveDisplaySources(
        _ sources: [WidgetSource],
        available: [WidgetSource]
    ) -> [WidgetSource] {
        sources.filter { available.contains($0) }
    }

    /// 按勾选的来源过滤快照，保持快照本来的顺序。选中的来源没数据时不拿别的来源顶替。
    static func select(
        _ sources: [WidgetSource],
        from snapshots: [WidgetSnapshot]
    ) -> [WidgetSnapshot] {
        select(sources, from: snapshots, available: availableSources())
    }

    static func select(
        _ sources: [WidgetSource],
        from snapshots: [WidgetSnapshot],
        available: [WidgetSource]
    ) -> [WidgetSnapshot] {
        let effective = effectiveDisplaySources(sources, available: available)
        return snapshots.filter { snapshot in
            effective.contains { $0.matches(snapshot) }
        }
    }

    /// 缓存是否已经旧到值得再抓一次。尺寸切换会重跑 timeline，这里用来跳过无谓的网络请求。
    ///
    /// 没有可用来源时返回 false：没有东西可抓，别白跑一轮。
    static func needsRefresh(
        _ snapshots: [WidgetSnapshot],
        sources: [WidgetSource],
        now: Date = Date(),
        maxAge: TimeInterval = 14 * 60,
        available: [WidgetSource]
    ) -> Bool {
        let effective = effectiveDisplaySources(sources, available: available)
        guard !effective.isEmpty else { return false }

        let missing = effective.contains { source in
            !snapshots.contains { source.matches($0) }
        }
        if missing { return true }

        let selected = select(sources, from: snapshots, available: available)
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
/// 小尺寸取勾选里的第一个，中尺寸并列显示全部勾选的；全部取消则显示空状态。
struct SelectSourcesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"
    static let description = IntentDescription("小尺寸显示勾选的第一个来源，中尺寸并排显示全部勾选的来源；全部取消勾选时显示空状态。")

    @Parameter(
        title: "显示来源",
        default: [.qwen, .deepseek, .cursor],
        optionsProvider: AvailableWidgetSourcesProvider())
    var sources: [WidgetSource]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
