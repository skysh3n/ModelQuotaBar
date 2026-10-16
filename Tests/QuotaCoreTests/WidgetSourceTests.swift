import Foundation
@testable import QuotaCore

enum WidgetSourceTests {
    static let suite = TestSuite("小组件来源过滤", [
        ("千问只匹配千问", testQwenMatchesOnlyQwen),
        ("DeepSeek 只匹配 DeepSeek", testDeepSeekMatchesOnlyDeepSeek),
        ("多选来源取并集且保持原顺序", testMultiSelectKeepsOrder),
        ("只勾一个时只留一个", testSingleSelection),
        ("一个都没勾时退回全部", testEmptySelectionFallsBackToAll),
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

    private static let all = [qwen, deepseek]

    /// 和小组件里 `QuotaEntry.selectedSnapshots` 同一套过滤规则。
    private static func select(_ sources: [WidgetSource]) -> [WidgetSnapshot] {
        guard !sources.isEmpty else { return all }
        return all.filter { snapshot in
            sources.contains { $0.matches(snapshot) }
        }
    }

    static func testQwenMatchesOnlyQwen() throws {
        try Expect.isTrue(WidgetSource.qwen.matches(qwen))
        try Expect.isTrue(!WidgetSource.qwen.matches(deepseek))
    }

    static func testDeepSeekMatchesOnlyDeepSeek() throws {
        try Expect.isTrue(WidgetSource.deepseek.matches(deepseek))
        try Expect.isTrue(!WidgetSource.deepseek.matches(qwen))
    }

    static func testMultiSelectKeepsOrder() throws {
        // 勾选顺序与展示顺序无关，始终按快照本来的顺序排。
        try Expect.equal(
            select([.deepseek, .qwen]).map(\.id),
            ["qwen-token-plan", "deepseek"])
    }

    static func testSingleSelection() throws {
        try Expect.equal(select([.qwen]).map(\.id), ["qwen-token-plan"])
        try Expect.equal(select([.deepseek]).map(\.id), ["deepseek"])
    }

    static func testEmptySelectionFallsBackToAll() throws {
        try Expect.equal(select([]).map(\.id), ["qwen-token-plan", "deepseek"])
    }
}