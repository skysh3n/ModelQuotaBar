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

    private static let all = [qwen, deepseek, cursor]

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
        let configured: Set<String> = ["qwen-token-plan", "deepseek", "cursor"]
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
}
