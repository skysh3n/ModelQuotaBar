import Foundation
@testable import QuotaCore

enum SharedStoreTests {
    static let suite = TestSuite("共享存储路径解析", [
        ("小组件进程用自己的容器目录", testWidgetProcessUsesOwnContainer),
        ("主应用进程拼出小组件容器目录", testAppProcessComposesWidgetContainer),
        ("两个进程必须解析到同一路径", testBothProcessesAgreeOnSamePath),
        ("拿不到 appSupport 时也能解析", testFallsBackWhenAppSupportMissing),
        ("部分刷新只覆盖抓到的来源", testMergeKeepsUnfetchedSources),
    ])

    private static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    /// 小组件跑在沙盒里：它的 `.applicationSupportDirectory` 已经在自己容器内部。
    private static let widgetAppSupport = URL(
        fileURLWithPath: "/Users/example/Library/Containers/\(SharedStore.widgetBundleIdentifier)/Data/Library/Application Support",
        isDirectory: true)

    /// 主应用没有沙盒：拿到的是真实的用户 Application Support。
    private static let plainAppSupport = URL(
        fileURLWithPath: "/Users/example/Library/Application Support",
        isDirectory: true)

    private static let expected = URL(
        fileURLWithPath: "/Users/example/Library/Containers/\(SharedStore.widgetBundleIdentifier)/Data/Library/Application Support/ModelQuotaBar",
        isDirectory: true)

    static func testWidgetProcessUsesOwnContainer() throws {
        let resolved = SharedStore.resolveContainerURL(appSupport: widgetAppSupport, home: home)
        try Expect.equal(resolved.path, expected.path)
    }

    static func testAppProcessComposesWidgetContainer() throws {
        let resolved = SharedStore.resolveContainerURL(appSupport: plainAppSupport, home: home)
        try Expect.equal(resolved.path, expected.path)
    }

    /// 这条不变量是整个共享方案成立的前提：任何一边拼错，
    /// 小组件就会显示「还没取到额度」而主应用毫无察觉。
    static func testBothProcessesAgreeOnSamePath() throws {
        let fromWidget = SharedStore.resolveContainerURL(appSupport: widgetAppSupport, home: home)
        let fromApp = SharedStore.resolveContainerURL(appSupport: plainAppSupport, home: home)
        try Expect.equal(fromWidget.path, fromApp.path)
    }

    static func testFallsBackWhenAppSupportMissing() throws {
        let resolved = SharedStore.resolveContainerURL(appSupport: nil, home: home)
        try Expect.equal(resolved.path, expected.path)
    }

    static func testMergeKeepsUnfetchedSources() throws {
        let cached = [
            WidgetSnapshot(
                id: "qwen-token-plan", vendor: "通义千问", planName: nil,
                primaryTitle: "每月", primaryRemainingRatio: 0.2, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: Date(timeIntervalSince1970: 1)),
            WidgetSnapshot(
                id: "cursor", vendor: "Cursor", planName: "Premium",
                primaryTitle: "每周", primaryRemainingRatio: 0.9, primaryResetsAt: nil,
                balanceRemaining: 0, balanceUnit: "USD",
                secondaryWindows: [], remainingDays: nil, updatedAt: Date(timeIntervalSince1970: 1)),
        ]
        let fresh = [
            WidgetSnapshot(
                id: "qwen-token-plan", vendor: "通义千问", planName: nil,
                primaryTitle: "每月", primaryRemainingRatio: 0.5, primaryResetsAt: nil,
                secondaryWindows: [], remainingDays: nil, updatedAt: Date(timeIntervalSince1970: 2)),
        ]
        let merged = SharedStore.mergeSnapshots(cached: cached, fresh: fresh)
        try Expect.equal(merged.map(\.id), ["qwen-token-plan", "cursor"])
        try Expect.equal(
            try Expect.notNil(try Expect.notNil(merged.first).primaryRemainingRatio),
            0.5, accuracy: 1e-9)
        try Expect.equal(
            try Expect.notNil(try Expect.notNil(merged.last).primaryRemainingRatio),
            0.9, accuracy: 1e-9)
    }
}