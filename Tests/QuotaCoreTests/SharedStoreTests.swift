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
        ("旧格式 WidgetSnapshot JSON 能解码成单块资源包", testLegacyWidgetSnapshotDecodes),
        ("新格式 WidgetSnapshot 带多块资源包可往返", testWidgetSnapshotResourcePackagesRoundTrip),
        ("WidgetSnapshot 同时有 resourcePackages 和 balanceRemaining 时不重复重建", testWidgetSnapshotBothFieldsNoDuplicate),
        ("QuotaSnapshot 同时有 resourcePackages 和 balance 时以 resourcePackages 为准", testQuotaSnapshotBothFieldsPriority),
        ("QuotaSnapshot resourcePackages 为空数组且 balance 有值时重建单块", testQuotaSnapshotEmptyPackagesWithBalance),
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

    // MARK: - 资源包向后兼容测试

    /// 旧格式 JSON（只有 balanceRemaining/balanceUnit，没有 resourcePackages）能解码成单块资源包
    static func testLegacyWidgetSnapshotDecodes() throws {
        // 模拟旧版 JSON：没有 resourcePackages 字段
        let legacyJSON = """
        {
            "id": "qoder",
            "vendor": "Qoder CN",
            "title": "Qoder CN Credits 用量",
            "planName": "专业版",
            "primaryTitle": "每月",
            "primaryRemainingRatio": 0.95,
            "primaryResetsAt": "2026-12-09T00:00:00Z",
            "primaryTotalQuota": 6000,
            "primaryUnit": "Credits",
            "balanceRemaining": 100,
            "balanceUnit": "Credits",
            "secondaryWindows": [],
            "remainingDays": 30,
            "updatedAt": "2026-11-09T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(legacyJSON.utf8))

        // 应从 balanceRemaining/balanceUnit 重建单块资源包
        try Expect.equal(snapshot.resourcePackages.count, 1)
        try Expect.equal(snapshot.resourcePackages[0].remaining, 100)
        try Expect.equal(snapshot.resourcePackages[0].unit, "Credits")
        try Expect.isNil(snapshot.resourcePackages[0].label)  // 旧数据没有标签

        // balanceRemaining 也应保留
        try Expect.equal(try Expect.notNil(snapshot.balanceRemaining), 100, accuracy: 1e-9)
    }

    /// 新格式 WidgetSnapshot 带多块资源包可往返编解码
    static func testWidgetSnapshotResourcePackagesRoundTrip() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetSnapshot(
            id: "qoder",
            vendor: "Qoder CN",
            title: "Qoder CN Credits 用量",
            planName: "专业版",
            primaryTitle: "每月",
            primaryRemainingRatio: 0.995,
            primaryResetsAt: expiresAt,
            primaryTotalQuota: 6000,
            primaryUnit: "Credits",
            balanceRemaining: 0,
            balanceUnit: "Credits",
            resourcePackages: [
                WidgetResourcePackage(
                    label: "附加资源包",
                    remaining: 0,
                    total: 1000,
                    unit: "Credits",
                    expiresAt: expiresAt),
                WidgetResourcePackage(
                    label: "Qwen 专属积分",
                    remaining: 1995,
                    total: 2000,
                    unit: "Credits",
                    expiresAt: expiresAt),
            ],
            secondaryWindows: [],
            remainingDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_792_806_998))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        try Expect.equal(decoded.resourcePackages.count, 2)
        try Expect.equal(decoded.resourcePackages[0].label, "附加资源包")
        try Expect.equal(decoded.resourcePackages[0].remaining, 0)
        try Expect.equal(decoded.resourcePackages[1].label, "Qwen 专属积分")
        try Expect.equal(decoded.resourcePackages[1].remaining, 1995)
    }

    /// WidgetSnapshot 同时有 resourcePackages 和 balanceRemaining 时不重复重建
    static func testWidgetSnapshotBothFieldsNoDuplicate() throws {
        // JSON 里同时有 resourcePackages 数组和 balanceRemaining 标量
        let json = """
        {
            "id": "qoder",
            "vendor": "Qoder CN",
            "planName": "专业版",
            "primaryTitle": "每月",
            "primaryRemainingRatio": 0.995,
            "primaryResetsAt": "2026-12-09T00:00:00Z",
            "primaryTotalQuota": 6000,
            "primaryUnit": "Credits",
            "balanceRemaining": 0,
            "balanceUnit": "Credits",
            "resourcePackages": [
                {"label": "附加资源包", "remaining": 0, "total": 1000, "unit": "Credits"},
                {"label": "专属资源包", "remaining": 1995, "total": 2000, "unit": "Credits"}
            ],
            "secondaryWindows": [],
            "remainingDays": 30,
            "updatedAt": "2026-11-09T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))

        // 应以 resourcePackages 为准，不重复重建
        try Expect.equal(snapshot.resourcePackages.count, 2)
        try Expect.equal(snapshot.resourcePackages[0].label, "附加资源包")
        try Expect.equal(snapshot.resourcePackages[1].label, "专属资源包")
        // balanceRemaining 保留原值（第一块的 remaining）
        try Expect.equal(snapshot.balanceRemaining, 0)
    }

    /// QuotaSnapshot 同时有 resourcePackages 和 balance 时以 resourcePackages 为准
    static func testQuotaSnapshotBothFieldsPriority() throws {
        let json = """
        {
            "planName": "专业版",
            "windows": [],
            "balance": {"remaining": 100, "total": 500, "unit": "Credits"},
            "resourcePackages": [
                {"balance": {"remaining": 0, "total": 1000, "unit": "Credits", "label": "附加资源包"}},
                {"balance": {"remaining": 1995, "total": 2000, "unit": "Credits", "label": "专属资源包"}}
            ],
            "updatedAt": "2026-11-09T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(QuotaSnapshot.self, from: Data(json.utf8))

        // 应以 resourcePackages 为准
        try Expect.equal(snapshot.resourcePackages.count, 2)
        try Expect.equal(snapshot.resourcePackages[0].label, "附加资源包")
        try Expect.equal(snapshot.resourcePackages[1].label, "专属资源包")
        // balance 计算属性应返回第一块
        try Expect.equal(snapshot.balance?.remaining, 0)
    }

    /// QuotaSnapshot resourcePackages 为空数组且 balance 有值时重建单块
    static func testQuotaSnapshotEmptyPackagesWithBalance() throws {
        let json = """
        {
            "windows": [],
            "balance": {"remaining": 110.5, "total": null, "unit": "CNY", "label": "账户余额"},
            "resourcePackages": [],
            "updatedAt": "2026-11-09T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(QuotaSnapshot.self, from: Data(json.utf8))

        // resourcePackages 为空数组时，应从 balance 重建单块
        try Expect.equal(snapshot.resourcePackages.count, 1)
        try Expect.equal(snapshot.resourcePackages[0].remaining, 110.5)
        try Expect.equal(snapshot.resourcePackages[0].unit, "CNY")
        try Expect.equal(snapshot.resourcePackages[0].label, "账户余额")
    }
}

enum AppSettingsTests {
    static let suite = TestSuite("启用来源迁移", [
        ("旧版本升级时并入已有凭据的来源", testMigratesCredentialedProviders),
        ("共享列表存在时不再自动启用凭据来源", testSharedListWins),
        ("共享列表优先，避免旧默认值把已关闭来源写回", testSharedListOverridesStaleDefaults),
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

    static func testSharedListOverridesStaleDefaults() throws {
        // UserDefaults 还留着千问，共享列表已经把它关掉：以共享列表为准。
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["qwen-token-plan"],
            shared: ["cursor", "deepseek", "qoder"],
            credentialed: [ProviderID("qwen-token-plan")])
        try Expect.equal(resolved.map(\.rawValue), ["cursor", "deepseek", "qoder"])
    }

    static func testDeduplicates() throws {
        let resolved = AppSettings.resolveInitialProviderIDs(
            stored: ["qwen-token-plan", "qwen-token-plan", "unknown-provider"],
            shared: nil,
            credentialed: [ProviderID("qwen-token-plan"), ProviderID("cursor")])
        try Expect.equal(resolved.map(\.rawValue), ["qwen-token-plan", "cursor"])
    }
}
