import Foundation
@testable import QuotaCore

enum SharedStoreTests {
    static let suite = TestSuite("共享存储", [
        ("小组件进程用自己的容器目录", testWidgetProcessUsesOwnContainer),
        ("主应用进程拼出小组件容器目录", testAppProcessComposesWidgetContainer),
        ("两个进程必须解析到同一路径", testBothProcessesAgreeOnSamePath),
        ("拿不到 appSupport 时也能解析", testFallsBackWhenAppSupportMissing),
        ("部分刷新只覆盖抓到的来源", testMergeKeepsUnfetchedSources),
        ("重复 id 的缓存不会崩溃", testMergeHandlesDuplicateIDs),
        ("内容比较忽略更新时间", testSnapshotContentComparison),
        ("启用列表可读写", testEnabledListRoundTrip),
        ("完整快照缓存可读写", testSnapshotCacheRoundTrip),
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

    private static func temporaryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
    }

    private static func snapshot(
        id: String = "cursor",
        updatedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            id: id,
            vendor: "Cursor",
            planName: "Premium",
            primaryTitle: "每周",
            primaryRemainingRatio: 0.9,
            primaryResetsAt: nil,
            balanceRemaining: 0,
            balanceUnit: "USD",
            secondaryWindows: [],
            remainingDays: nil,
            updatedAt: updatedAt)
    }

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

    static func testMergeHandlesDuplicateIDs() throws {
        // 缓存文件损坏/手改可能产生重复 id；旧实现用 uniqueKeysWithValues 会崩。
        let merged = SharedStore.mergeSnapshots(
            cached: [snapshot(id: "cursor"), snapshot(id: "cursor")],
            fresh: [snapshot(id: "deepseek")])
        try Expect.equal(merged.map(\.id).sorted(), ["cursor", "deepseek"])
    }

    static func testSnapshotContentComparison() throws {
        let base = snapshot(updatedAt: Date(timeIntervalSince1970: 10))
        var sameContentNewTime = base
        sameContentNewTime.updatedAt = Date(timeIntervalSince1970: 20)
        try Expect.isTrue(SharedStore.snapshotsHaveSameContent([base], [sameContentNewTime]))

        var changedBalance = sameContentNewTime
        changedBalance.balanceRemaining = 1
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], [changedBalance]))
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], []))
    }

    static func testEnabledListRoundTrip() throws {
        let url = temporaryURL("enabled")
        defer { try? FileManager.default.removeItem(at: url) }

        try Expect.isNil(SharedStore.loadEnabledProviderIDs(from: url))
        SharedStore.saveEnabledProviderIDs(["qwen-token-plan", "cursor"], to: url)
        try Expect.equal(
            SharedStore.loadEnabledProviderIDs(from: url),
            ["qwen-token-plan", "cursor"])
    }

    static func testSnapshotCacheRoundTrip() throws {
        let url = temporaryURL("quota-cache")
        defer { try? FileManager.default.removeItem(at: url) }

        let date = Date(timeIntervalSince1970: 1_792_806_998)
        let snapshot = QuotaSnapshot(
            accountLabel: "user@example.com",
            planName: "Premium",
            status: "VALID",
            isAvailable: true,
            windows: [
                QuotaWindow(
                    id: "weekly",
                    title: "每周",
                    usedRatio: 0.13,
                    resetsAt: date,
                    totalQuota: 46.15,
                    unit: "USD"),
            ],
            balance: CreditBalance(remaining: 12.5, total: 20, unit: "USD"),
            expiresAt: date,
            remainingDays: 3,
            updatedAt: date)
        SnapshotCache.save(["cursor": snapshot], to: url)
        let loaded = SnapshotCache.load(from: url)
        try Expect.equal(loaded["cursor"], snapshot)
        try Expect.equal(loaded.count, 1)
    }
}

enum AppSettingsTests {
    static let suite = TestSuite("启用来源迁移", [
        ("旧版本升级时并入已有凭据的来源", testMigratesCredentialedProviders),
        ("共享列表存在时不再自动启用凭据来源", testSharedListWins),
        ("本地列表优先于共享列表", testStoredListWins),
        ("重复和未知 id 会被清掉", testDeduplicates),
    ])

    static func testMigratesCredentialedProviders() throws {
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["qwen-token-plan"],
            shared: nil,
            credentialed: [ProviderID("deepseek"), ProviderID("cursor")])
        try Expect.equal(resolved.map(\.rawValue), ["qwen-token-plan", "deepseek", "cursor"])
    }

    static func testSharedListWins() throws {
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["qwen-token-plan"],
            shared: ["qwen-token-plan"],
            credentialed: [ProviderID("deepseek")])
        try Expect.equal(resolved.map(\.rawValue), ["qwen-token-plan"])
    }

    static func testStoredListWins() throws {
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["cursor"],
            shared: ["qwen-token-plan"],
            credentialed: [])
        try Expect.equal(resolved.map(\.rawValue), ["cursor"])
    }

    static func testDeduplicates() throws {
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["qwen-token-plan", "qwen-token-plan", "unknown-provider"],
            shared: nil,
            credentialed: [ProviderID("qwen-token-plan"), ProviderID("cursor")])
        try Expect.equal(resolved.map(\.rawValue), ["qwen-token-plan", "cursor"])
    }
}
