import Foundation
@testable import QuotaCore

enum WidgetSourceTests {
    static let suite = TestSuite("小组件来源过滤", [
        ("千问只匹配千问", testQwenMatchesOnlyQwen),
        ("DeepSeek 只匹配 DeepSeek", testDeepSeekMatchesOnlyDeepSeek),
        ("Cursor 只匹配 Cursor", testCursorMatchesOnlyCursor),
        ("多选来源取并集且保持原顺序", testMultiSelectKeepsOrder),
        ("只勾一个时只留一个", testSingleSelection),
        ("一个都没勾时显示空", testEmptySelectionShowsNothing),
        ("勾选的来源都没数据时显示空", testNoMatchShowsNothing),
        ("千问+DeepSeek 的勾选不会自动加回 Cursor", testLegacyPairDoesNotAddCursor),
        ("每个来源都对应一个已注册的 Provider", testSourcesMatchRegistry),
        ("启用列表和凭据共同决定可用来源", testAvailableSourcesHonorsEnabledList),
        ("缓存够新时切换尺寸不必再抓", testNeedsRefreshSkipsFreshCache),
        ("缺勾选来源或过旧时才需要刷新", testNeedsRefreshWhenMissingOrStale),
        ("没有可用来源时不刷新", testNeedsRefreshSkipsWhenNothingAvailable),
        ("主界面关掉的来源不进有效勾选", testEffectiveSourcesDropsUnavailable),
        ("停用来源排在前面也不挤掉可用来源", testDisplaySourcesFiltersBeforeLimit),
        ("小组件只显示主应用打开的来源", testWidgetDisplayFollowsEnabledList),
        ("勾选不会被启用列表里的其他来源顶替", testSelectionDoesNotBackfill),
        ("编辑列表不含主应用关掉的来源", testSelectableSourcesOmitsDisabled),
        ("关掉的开关不计入，打开的保持原顺序", testOpenedSourcesSkipsOffSwitches),
        ("主界面关掉任何一个来源都不画", testTurningOffAnySourceOmitsIt),
        ("凭据读不到时仍用已启用的缓存", testWidgetDisplayFallsBackToCache),
        ("快照按启用顺序而不是文件顺序", testOrderedSnapshotsFollowsSources),
        ("可用来源解析失败时不清空缓存", testRefreshKeepIDsDoesNotWipeCache),
        ("登录过期来源会挤进可见位置", testLoginExpiredIsPromotedIntoView),
    ])

    private static let qwen = WidgetSnapshot(
        id: "qwen-token-plan", vendor: "通义千问", planName: "Lite 轻量版",
        primaryTitle: "每月", primaryRemainingRatio: 0.18, primaryResetsAt: nil,
        balanceRemaining: nil, balanceUnit: nil,
        secondaryWindows: [], remainingDays: 20, updatedAt: Date())

    private static let deepseek = WidgetSnapshot(
        id: "deepseek", vendor: "DeepSeek", planName: "API 余额",
        primaryTitle: nil, primaryRemainingRatio: nil, primaryResetsAt: nil,
        balanceRemaining: 45.54, balanceUnit: "CNY",
        secondaryWindows: [], remainingDays: nil, updatedAt: Date())

    private static let cursor = WidgetSnapshot(
        id: "cursor", vendor: "Cursor", planName: "Pro",
        primaryTitle: "每月", primaryRemainingRatio: 0.383, primaryResetsAt: nil,
        balanceRemaining: nil, balanceUnit: nil,
        secondaryWindows: [], remainingDays: nil, updatedAt: Date())

    private static let qoder = WidgetSnapshot(
        id: "qoder", vendor: "Qoder CN", planName: "专业版",
        primaryTitle: "每月", primaryRemainingRatio: 0.05, primaryResetsAt: nil,
        balanceRemaining: 100, balanceUnit: "Credits",
        secondaryWindows: [], remainingDays: nil, updatedAt: Date())

    private static let all = [qwen, deepseek, cursor, qoder]

    private static func select(_ sources: [WidgetSource], from snapshots: [WidgetSnapshot] = all) -> [String] {
        // 单测不读本机凭据，按「全部可用」验证勾选逻辑。
        WidgetSource.select(sources, from: snapshots, available: Array(WidgetSource.allCases)).map(\.id)
    }

    static func testQwenMatchesOnlyQwen() throws {
        try Expect.isTrue(WidgetSource.qwen.matches(qwen))
        try Expect.isTrue(!WidgetSource.qwen.matches(deepseek))
        try Expect.isTrue(!WidgetSource.qwen.matches(cursor))
    }

    static func testDeepSeekMatchesOnlyDeepSeek() throws {
        try Expect.isTrue(WidgetSource.deepseek.matches(deepseek))
        try Expect.isTrue(!WidgetSource.deepseek.matches(qwen))
        try Expect.isTrue(!WidgetSource.deepseek.matches(cursor))
    }

    static func testCursorMatchesOnlyCursor() throws {
        try Expect.isTrue(WidgetSource.cursor.matches(cursor))
        try Expect.isTrue(!WidgetSource.cursor.matches(qwen))
        try Expect.isTrue(!WidgetSource.cursor.matches(deepseek))
    }

    static func testMultiSelectKeepsOrder() throws {
        // 勾选顺序与展示顺序无关，始终按快照本来的顺序排。
        try Expect.equal(select([.cursor, .qwen]), ["qwen-token-plan", "cursor"])
        try Expect.equal(select([.cursor, .deepseek, .qwen]), ["qwen-token-plan", "deepseek", "cursor"])
    }

    static func testSingleSelection() throws {
        try Expect.equal(select([.qwen]), ["qwen-token-plan"])
        try Expect.equal(select([.deepseek]), ["deepseek"])
        try Expect.equal(select([.cursor]), ["cursor"])
    }

    static func testEmptySelectionShowsNothing() throws {
        // 全部取消勾选就是空状态，不再兜底成全部来源。
        try Expect.equal(select([]), [])
    }

    static func testNoMatchShowsNothing() throws {
        // 勾选的来源没数据时不拿别的来源顶替。
        try Expect.equal(select([.qwen, .deepseek], from: [cursor]), [])
        try Expect.equal(select([.qwen], from: []), [])
    }

    static func testLegacyPairDoesNotAddCursor() throws {
        // 用户可能是从旧版本升上来的，只勾了千问+DeepSeek；不能再把 Cursor 塞回来。
        try Expect.equal(select([.qwen, .deepseek]), ["qwen-token-plan", "deepseek"])
        try Expect.equal(select([.qwen]), ["qwen-token-plan"])
    }

    static func testSourcesMatchRegistry() throws {
        let registered = Set(ProviderRegistry.all.map(\.id.rawValue))
        for source in WidgetSource.allCases {
            try Expect.isTrue(registered.contains(source.rawValue), "\(source) 没有对应的 Provider")
        }
    }

    static func testAvailableSourcesHonorsEnabledList() throws {
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor", "qoder"]
        try Expect.equal(
            WidgetSource.availableSources(
                enabled: ["qwen-token-plan", "deepseek"],
                configured: configured),
            [.qwen, .deepseek])
        // 旧版本没有共享启用列表时退回凭据。
        try Expect.equal(
            WidgetSource.availableSources(enabled: nil, configured: ["cursor"]),
            [.cursor])
        // 启用列表为空 = 全关掉。
        try Expect.equal(
            WidgetSource.availableSources(enabled: [], configured: configured),
            [])
        // 启用但没凭据的也不能用。
        try Expect.equal(
            WidgetSource.availableSources(enabled: ["cursor"], configured: ["qwen-token-plan"]),
            [])
    }

    static func testNeedsRefreshSkipsFreshCache() throws {
        let now = Date()
        let fresh = [
            WidgetSnapshot(
                id: "qwen-token-plan", vendor: "通义千问", planName: nil,
                primaryTitle: "每月", primaryRemainingRatio: 0.5, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: now.addingTimeInterval(-60)),
            WidgetSnapshot(
                id: "cursor", vendor: "Cursor", planName: nil,
                primaryTitle: "每周", primaryRemainingRatio: 0.9, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: now.addingTimeInterval(-120)),
        ]
        try Expect.isTrue(!WidgetSource.needsRefresh(
            fresh, sources: [.qwen, .cursor], now: now, available: [.qwen, .cursor]))
    }

    static func testNeedsRefreshWhenMissingOrStale() throws {
        let now = Date()
        let onlyQwen = [
            WidgetSnapshot(
                id: "qwen-token-plan", vendor: "通义千问", planName: nil,
                primaryTitle: "每月", primaryRemainingRatio: 0.5, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: now),
        ]
        try Expect.isTrue(WidgetSource.needsRefresh(
            onlyQwen, sources: [.qwen, .cursor], now: now, available: [.qwen, .cursor]))

        let stale = [
            WidgetSnapshot(
                id: "qwen-token-plan", vendor: "通义千问", planName: nil,
                primaryTitle: "每月", primaryRemainingRatio: 0.5, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: now.addingTimeInterval(-20 * 60)),
        ]
        try Expect.isTrue(WidgetSource.needsRefresh(
            stale, sources: [.qwen], now: now, available: [.qwen]))
    }

    static func testNeedsRefreshSkipsWhenNothingAvailable() throws {
        let now = Date()
        try Expect.isTrue(!WidgetSource.needsRefresh(
            [], sources: [.qwen], now: now, available: []))
    }

    static func testEffectiveSourcesDropsUnavailable() throws {
        try Expect.equal(
            WidgetSource.effectiveDisplaySources(
                [.qwen, .deepseek, .cursor],
                available: [.cursor]),
            [.cursor])
        // 勾选的来源都不可用时返回空，不拿别的来源顶替。
        try Expect.equal(
            WidgetSource.effectiveDisplaySources(
                [.qwen, .deepseek],
                available: [.cursor]),
            [])
        // available 为空表示没有可用来源，同样返回空。
        try Expect.equal(
            WidgetSource.effectiveDisplaySources([.qwen], available: []),
            [])
    }

    static func testDisplaySourcesFiltersBeforeLimit() throws {
        // 旧勾选里千问排第一但已停用；先过滤再截断，两个可用来源都要保住。
        try Expect.equal(
            WidgetSource.displaySources(
                [.qwen, .cursor, .deepseek],
                available: [.deepseek, .cursor, .qoder]),
            [.cursor, .deepseek])
        // 可用来源超过两个时只取前两个。
        try Expect.equal(
            WidgetSource.displaySources(
                [.deepseek, .cursor, .qoder],
                available: [.deepseek, .cursor, .qoder]),
            [.deepseek, .cursor])
    }

    static func testWidgetDisplayFollowsEnabledList() throws {
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor", "qoder"]
        // 主应用关掉千问后，小组件不能再凭自己的旧勾选把它显示出来。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                enabled: ["cursor", "deepseek", "qoder"],
                configured: configured),
            [.cursor, .deepseek])
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                enabled: ["qoder"],
                configured: configured),
            [.qoder])
        try Expect.equal(
            WidgetSource.widgetDisplaySources(enabled: [], configured: configured),
            [])
    }

    static func testSelectionDoesNotBackfill() throws {
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor", "qoder"]
        let enabled = ["cursor", "deepseek", "qoder"]
        // 勾了千问和 Qoder：千问已被主应用关掉，只能画 Qoder，不能把 Cursor 补进来。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                toggles: [.qwen, .qoder],
                enabled: enabled,
                configured: configured),
            [.qoder])
        // 勾了 DeepSeek 和 Qoder，就不能再出现没勾的 Cursor。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                toggles: [.deepseek, .qoder],
                enabled: enabled,
                configured: configured),
            [.deepseek, .qoder])
        // 勾的来源全被主应用关掉时显示空，不用别的来源顶。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                toggles: [.qwen],
                enabled: enabled,
                configured: configured),
            [])
    }

    static func testTurningOffAnySourceOmitsIt() throws {
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor", "qoder"]
        let toggles = Array(WidgetSource.allCases)
        for disabled in WidgetSource.allCases {
            let enabled = WidgetSource.allCases
                .filter { $0 != disabled }
                .map(\.rawValue)
            let shown = WidgetSource.widgetDisplaySources(
                toggles: toggles,
                enabled: enabled,
                configured: configured)
            try Expect.isTrue(!shown.contains(disabled), "关掉 \(disabled.rawValue) 后不应再画")
            let kept = WidgetSource.droppingDisabled(all, enabled: enabled).map(\.id)
            try Expect.isTrue(!kept.contains(disabled.rawValue))
        }
    }

    static func testOpenedSourcesSkipsOffSwitches() throws {
        // 通义千问开关关掉时，不把它算进要画的来源。
        try Expect.equal(
            WidgetSource.openedSources(
                showQwen: false,
                showDeepSeek: true,
                showCursor: false,
                showQoder: true),
            [.deepseek, .qoder])
        // 四个都开时仍按原顺序交给后面截到两个，这里不丢后两个。
        try Expect.equal(
            WidgetSource.openedSources(
                showQwen: true,
                showDeepSeek: true,
                showCursor: true,
                showQoder: true),
            [.qwen, .deepseek, .cursor, .qoder])
    }

    static func testSelectableSourcesOmitsDisabled() throws {
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor", "qoder"]
        try Expect.equal(
            WidgetSource.selectableSources(
                enabled: ["cursor", "deepseek", "qoder"],
                configured: configured),
            [.cursor, .deepseek, .qoder])
        try Expect.equal(
            WidgetSource.droppingDisabled(
                [qwen, cursor],
                enabled: ["cursor", "deepseek", "qoder"]).map(\.id),
            ["cursor"])
    }

    static func testWidgetDisplayFallsBackToCache() throws {
        // 启用列表还在，但这一轮没读到凭据：不能因此把小组件画空。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                enabled: ["cursor", "deepseek", "qoder"],
                configured: [],
                cachedIDs: ["deepseek", "cursor", "qoder", "qwen-token-plan"]),
            [.cursor, .deepseek])
        // 主应用明确全关时，缓存里有千问也不能再显示。
        try Expect.equal(
            WidgetSource.widgetDisplaySources(
                enabled: [],
                configured: [],
                cachedIDs: ["qwen-token-plan", "cursor"]),
            [])
    }

    static func testOrderedSnapshotsFollowsSources() throws {
        try Expect.equal(
            WidgetSource.orderedSnapshots([.cursor, .deepseek], from: all).map(\.id),
            ["cursor", "deepseek"])
        // 没有快照的来源跳过，不拿别的来源顶。
        try Expect.equal(
            WidgetSource.orderedSnapshots([.qwen], from: [cursor, deepseek]).map(\.id),
            [])
    }

    static func testRefreshKeepIDsDoesNotWipeCache() throws {
        let keepCursor: Set<String>? = Set(["cursor", "deepseek"])
        try Expect.equal(
            WidgetSource.refreshKeepIDs(available: [.cursor, .deepseek], enabled: ["cursor"]),
            keepCursor)
        // 主应用全关，才允许用空集合把缓存清掉。
        let keepNone: Set<String>? = []
        try Expect.equal(
            WidgetSource.refreshKeepIDs(available: [], enabled: []),
            keepNone)
        // 凭据没读到、启用列表也没读到：不要动缓存。
        try Expect.isTrue(WidgetSource.refreshKeepIDs(available: [], enabled: nil) == nil)
        try Expect.isTrue(
            WidgetSource.refreshKeepIDs(available: [], enabled: ["cursor", "deepseek"]) == nil)
    }

    static func testLoginExpiredIsPromotedIntoView() throws {
        let expired = WidgetSnapshot.loginExpired(
            id: ProviderID("qoder"),
            vendor: "Qoder CN",
            title: "Qoder CN Credits 用量")
        let displayed = [cursor, deepseek]
        let promoted = WidgetSource.promotingLoginExpired(
            displayed,
            from: displayed + [expired])
        try Expect.equal(promoted.map(\.id), ["qoder", "cursor"])
        try Expect.isTrue(try Expect.notNil(promoted.first).hasError)

        let unchanged = WidgetSource.promotingLoginExpired(displayed, from: displayed)
        try Expect.equal(unchanged.map(\.id), ["cursor", "deepseek"])
    }
}
