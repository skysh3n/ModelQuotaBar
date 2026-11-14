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

    func perform() async throws -> some IntentResult {
        // 刷新主应用当前打开的来源，不读小组件自己的旧勾选。
        // 凭据暂时读不到时不要把缓存清空，否则桌面小组件会被洗成空状态。
        let available = WidgetSource.availableSources()
        let enabled = SharedStore.loadEnabledProviderIDs()
        if let ids = WidgetSource.refreshKeepIDs(available: available, enabled: enabled) {
            let fresh = await QuotaFetcher.fetchWidgetSnapshots(ids: ids)
            SharedStore.saveMerging(fresh, keeping: ids)
        }
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
/// 新增厂商时在这里加 case，并同步 `matches`、`displayName` 和配置意图里的开关。
///
/// **最多显示两个来源**：中尺寸卡片并排显示时，三个来源会太挤；小尺寸只取第一个。
/// 开关可以都在，但同一时间只认前两个打开的。
enum WidgetSource: String, CaseIterable {
    case qwen = "qwen-token-plan"
    case deepseek = "deepseek"
    case cursor = "cursor"
    case qoder = "qoder"

    /// 小组件最多显示的来源数量。中尺寸并排显示时，三个来源会太挤。
    static let maxSourcesPerWidget = 2

    var displayName: String {
        switch self {
        case .qwen: "通义千问"
        case .deepseek: "DeepSeek"
        case .cursor: "Cursor"
        case .qoder: "Qoder CN"
        }
    }

    func matches(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.id == rawValue
    }

    /// 主界面已启用且填好凭据的来源，顺序与主应用的启用列表一致。
    ///
    /// 启用列表由主应用镜像到共享目录；共享文件不存在（旧版本）时退回「看凭据」。
    /// 两个条件都满足才可用：启用但没填凭据的抓不到数据，有凭据但被关掉的也不该出现。
    static func configuredProviderIDs() -> Set<String> {
        Set(ProviderRegistry.all
            .filter { CredentialStore.loadCredential(for: $0.id).isComplete(for: $0.credentialFields) }
            .map(\.id.rawValue))
    }

    static func availableSources() -> [WidgetSource] {
        orderedAvailableSources(
            enabled: SharedStore.loadEnabledProviderIDs(),
            configured: configuredProviderIDs())
    }

    /// 小组件实际要画的来源。
    ///
    /// 先看小组件自己勾了哪些，再丢掉主应用已经关掉、或没填凭据的。
    /// 不会用启用列表里靠前的来源（例如 Cursor）去顶替没勾的项。
    /// 凭据文件暂时读不到时，用缓存里仍被启用的来源判断，避免整张卡被洗空。
    static func widgetDisplaySources(
        toggles: [WidgetSource] = Array(WidgetSource.allCases),
        cachedIDs: Set<String> = []
    ) -> [WidgetSource] {
        widgetDisplaySources(
            toggles: toggles,
            enabled: SharedStore.loadEnabledProviderIDs(),
            configured: configuredProviderIDs(),
            cachedIDs: cachedIDs)
    }

    static func widgetDisplaySources(
        toggles: [WidgetSource] = Array(WidgetSource.allCases),
        enabled: [String]?,
        configured: Set<String>,
        cachedIDs: Set<String> = []
    ) -> [WidgetSource] {
        let allowed = selectableSources(
            enabled: enabled,
            configured: configured,
            cachedIDs: cachedIDs)
        let pickedIDs = Set(toggles.map(\.rawValue))
        // 保持主应用启用列表的顺序，但只留这个小组件勾中的。没勾的不补位。
        // 主应用关掉的来源不在 allowed 里，勾着也不会画出来。
        let picked = allowed.filter { pickedIDs.contains($0.rawValue) }
        return Array(picked.prefix(maxSourcesPerWidget))
    }

    /// 编辑小组件时能选的来源：主应用打开且凭据完整的全部来源，不截到两个。
    ///
    /// 主应用关掉的来源，哪一个都不会出现在这个列表里。
    static func selectableSources(
        enabled: [String]?,
        configured: Set<String>,
        cachedIDs: Set<String> = []
    ) -> [WidgetSource] {
        let usable: Set<String>
        if !configured.isEmpty {
            usable = configured
        } else if enabled != nil {
            usable = cachedIDs
        } else {
            usable = configured
        }
        return orderedAvailableSources(enabled: enabled, configured: usable)
    }

    static func selectableSources() -> [WidgetSource] {
        selectableSources(
            enabled: SharedStore.loadEnabledProviderIDs(),
            configured: configuredProviderIDs(),
            cachedIDs: Set(SharedStore.loadSnapshots().map(\.id)))
    }

    /// 启用列表明确存在时，丢掉其中没有的快照。列表缺失（旧版本）时不动。
    static func droppingDisabled(
        _ snapshots: [WidgetSnapshot],
        enabled: [String]? = nil
    ) -> [WidgetSnapshot] {
        let enabled = enabled ?? SharedStore.loadEnabledProviderIDs()
        guard let enabled else { return snapshots }
        let allowed = Set(enabled)
        return snapshots.filter { allowed.contains($0.id) }
    }

    /// 打开的开关。关掉的不计入。卡片最多画两个，在 `widgetDisplaySources` 里截。
    static func openedSources(
        showQwen: Bool,
        showDeepSeek: Bool,
        showCursor: Bool,
        showQoder: Bool
    ) -> [WidgetSource] {
        let flags: [(WidgetSource, Bool)] = [
            (.qwen, showQwen),
            (.deepseek, showDeepSeek),
            (.cursor, showCursor),
            (.qoder, showQoder),
        ]
        return flags.filter(\.1).map(\.0)
    }

    /// 按来源顺序取快照。没有数据的来源跳过，不用别的来源顶替，也不按快照文件顺序重排。
    static func orderedSnapshots(
        _ sources: [WidgetSource],
        from snapshots: [WidgetSnapshot]
    ) -> [WidgetSnapshot] {
        sources.compactMap { source in
            snapshots.first { source.matches($0) }
        }
    }

    /// 登录过期的来源插到最前，挤进小组件可见的位置。
    ///
    /// 卡片最多画两个，过期来源如果排在后面，桌面上就完全看不到提示。
    /// 这里只改展示顺序，不发起刷新。
    static func promotingLoginExpired(
        _ displayed: [WidgetSnapshot],
        from allowed: [WidgetSnapshot],
        limit: Int = maxSourcesPerWidget
    ) -> [WidgetSnapshot] {
        let expired = allowed.filter(\.hasError)
        guard !expired.isEmpty else { return displayed }
        var seen = Set<String>()
        var result: [WidgetSnapshot] = []
        for snapshot in expired + displayed {
            guard seen.insert(snapshot.id).inserted else { continue }
            result.append(snapshot)
            if result.count == limit { break }
        }
        return result
    }

    /// 刷新时允许写回缓存的来源。
    ///
    /// 返回 nil 表示这次不要动缓存：可用来源没解析出来，但主应用也没有明确「全部关掉」。
    /// 这时若用空集合去 `saveMerging`，会把已有快照洗掉，小组件就变成「一个都没了」。
    static func refreshKeepIDs(
        available: [WidgetSource],
        enabled: [String]?
    ) -> Set<String>? {
        let ids = Set(available.map(\.rawValue))
        if !ids.isEmpty { return ids }
        if let enabled, enabled.isEmpty { return [] }
        return nil
    }

    /// 按启用列表的顺序返回可用来源。`enabled == nil` 时退回全部已配置来源。
    static func orderedAvailableSources(
        enabled: [String]?,
        configured: Set<String>
    ) -> [WidgetSource] {
        guard let enabled else {
            return availableSources(enabled: nil, configured: configured)
        }
        var seen = Set<String>()
        return enabled.compactMap { raw in
            guard seen.insert(raw).inserted,
                  configured.contains(raw),
                  let source = WidgetSource(rawValue: raw)
            else { return nil }
            return source
        }
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

    /// 实际参与显示/抓取的来源：**先按可用性过滤，再截到上限**。
    ///
    /// 顺序不能反：保存的勾选里可能还留着已停用的旧来源（例如千问），它若排在
    /// 前面，提前截断会把后面的可用来源挤掉，表现为「勾了两个只显示一个」。
    static func displaySources(
        _ sources: [WidgetSource],
        available: [WidgetSource]
    ) -> [WidgetSource] {
        Array(effectiveDisplaySources(sources, available: available).prefix(maxSourcesPerWidget))
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
    /// 登录过期只在小组件上提示，不因此提前刷新——重新登录要用户自己做。
    static func needsRefresh(
        _ snapshots: [WidgetSnapshot],
        sources: [WidgetSource],
        now: Date = Date(),
        maxAge: TimeInterval = 14 * 60,
        available: [WidgetSource]
    ) -> Bool {
        let effective = displaySources(sources, available: available)
        guard !effective.isEmpty else { return false }

        let missing = effective.contains { source in
            !snapshots.contains { source.matches($0) }
        }
        if missing { return true }

        let selected = select(effective, from: snapshots, available: available)
        guard let oldest = selected.map(\.updatedAt).min() else { return true }
        return now.timeIntervalSince(oldest) > maxAge
    }
}

/// 小组件的配置意图：每个来源一个开关。
///
/// 四个开关都留着。某个来源的开关关掉时不画；主界面把任何一个来源关掉时，
/// 即使小组件开关还开着，也不画。
/// 同一时间只认两个打开的开关，多开的不补进卡片。
///
/// 不要改成多选列表：macOS 会按这些开关存档。换参数类型会让编辑面板变样，
/// 旧配置也对不上。也不要在 `perform()` 里回写开关，系统会把配置判无效，小组件变空白。
struct SelectSourcesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择来源"
    static let description = IntentDescription("用开关选择来源，最多同时打开两个。关掉的不显示。")

    @Parameter(title: "通义千问", default: true)
    var showQwen: Bool

    @Parameter(title: "DeepSeek", default: true)
    var showDeepSeek: Bool

    @Parameter(title: "Cursor", default: true)
    var showCursor: Bool

    @Parameter(title: "Qoder CN", default: true)
    var showQoder: Bool

    /// 打开的开关，按来源顺序，最多两个。关掉的不在里面。
    var sources: [WidgetSource] {
        WidgetSource.openedSources(
            showQwen: showQwen,
            showDeepSeek: showDeepSeek,
            showCursor: showCursor,
            showQoder: showQoder)
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
