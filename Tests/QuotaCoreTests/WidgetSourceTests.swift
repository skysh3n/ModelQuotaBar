import Foundation
@testable import QuotaCore

enum WidgetSourceTests {
    static let suite = TestSuite("小组件来源过滤", [
        ("自动匹配全部", testAutoMatchesAll),
        ("千问只匹配千问", testQwenMatchesOnlyQwen),
        ("DeepSeek 只匹配 DeepSeek", testDeepSeekMatchesOnlyDeepSeek),
        ("按来源过滤快照列表", testFilteredReturnsCorrectSubset),
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

    static func testAutoMatchesAll() throws {
        try Expect.isTrue(WidgetSource.auto.matches(qwen))
        try Expect.isTrue(WidgetSource.auto.matches(deepseek))
    }

    static func testQwenMatchesOnlyQwen() throws {
        try Expect.isTrue(WidgetSource.qwen.matches(qwen))
        try Expect.isTrue(!WidgetSource.qwen.matches(deepseek))
    }

    static func testDeepSeekMatchesOnlyDeepSeek() throws {
        try Expect.isTrue(WidgetSource.deepseek.matches(deepseek))
        try Expect.isTrue(!WidgetSource.deepseek.matches(qwen))
    }

    static func testFilteredReturnsCorrectSubset() throws {
        let all = [qwen, deepseek]
        try Expect.equal(WidgetSource.auto.filtered(all).map(\.id), ["qwen-token-plan", "deepseek"])
        try Expect.equal(WidgetSource.qwen.filtered(all).map(\.id), ["qwen-token-plan"])
        try Expect.equal(WidgetSource.deepseek.filtered(all).map(\.id), ["deepseek"])
    }
}