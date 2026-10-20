import Foundation
@testable import QuotaCore

enum WidgetSourceTests {
    static let suite = TestSuite("小组件来源过滤", [
        ("千问只匹配千问", testQwenMatchesOnlyQwen),
        ("DeepSeek 只匹配 DeepSeek", testDeepSeekMatchesOnlyDeepSeek),
        ("Cursor 只匹配 Cursor", testCursorMatchesOnlyCursor),
        ("多选来源取并集且保持原顺序", testMultiSelectKeepsOrder),
        ("只勾一个时只留一个", testSingleSelection),
        ("一个都没勾时退回全部", testEmptySelectionFallsBackToAll),
        ("勾选的来源都没数据时退回全部", testNoMatchFallsBackToAll),
        ("升级前的默认勾选会带上新增来源", testLegacyDefaultIncludesNewSources),
        ("每个来源都对应一个已注册的 Provider", testSourcesMatchRegistry),
        ("缓存够新时切换尺寸不必再抓", testNeedsRefreshSkipsFreshCache),
        ("缺勾选来源或过旧时才需要刷新", testNeedsRefreshWhenMissingOrStale),
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

    static func testEmptySelectionFallsBackToAll() throws {
        try Expect.equal(select([]), ["qwen-token-plan", "deepseek", "cursor"])
    }

    static func testNoMatchFallsBackToAll() throws {
        // 只配置了 Cursor，但小组件勾的是千问和 DeepSeek：不能显示空白。
        try Expect.equal(select([.qwen, .deepseek], from: [cursor]), ["cursor"])
        try Expect.equal(select([.qwen], from: []), [])
    }

    static func testLegacyDefaultIncludesNewSources() throws {
        try Expect.equal(
            select(WidgetSource.legacyDefault),
            ["qwen-token-plan", "deepseek", "cursor"])
        // 用户只留千问时不要把 Cursor 加回来。
        try Expect.equal(select([.qwen]), ["qwen-token-plan"])
    }

    static func testSourcesMatchRegistry() throws {
        let registered = Set(ProviderRegistry.all.map(\.id.rawValue))
        for source in WidgetSource.allCases {
            try Expect.isTrue(registered.contains(source.rawValue), "\(source) 没有对应的 Provider")
        }
    }

    static func testNeedsRefreshSkipsFreshCache() throws {
        let now = Date()
        // 不能用 [.qwen, .deepseek]：那是升级前的默认勾选，会被扩成全部来源。
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

    static func testEffectiveSourcesDropsUnavailable() throws {
        try Expect.equal(
            WidgetSource.effectiveDisplaySources(
                [.qwen, .deepseek, .cursor],
                available: [.cursor]),
            [.cursor])
        // 升级前的默认勾选也会被裁成当前仍启用的。
        try Expect.equal(
            WidgetSource.effectiveDisplaySources(
                WidgetSource.legacyDefault,
                available: [.cursor]),
            [.cursor])
        // 可用列表为空时不过滤（测试 / 尚未配置）。
        try Expect.equal(
            WidgetSource.effectiveDisplaySources([.qwen], available: []),
            [.qwen])
    }
}
