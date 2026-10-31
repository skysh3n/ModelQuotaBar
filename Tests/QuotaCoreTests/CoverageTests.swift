import Foundation
@testable import QuotaCore

/// 补齐这轮改动里之前没有覆盖到的逻辑：凭据存储、发布策略、来源过滤、快照转换、
/// 千问/Cursor 的边角解析、网关错误分类、模型辅助代码。
enum CredentialStoreTests {
    static let suite = TestSuite("凭据文件存储", [
        ("保存/读取凭据并收紧到 0600", testSaveLoadRoundTripAndPermissions),
        ("空凭据会移除对应来源", testEmptyCredentialRemovesProvider),
        ("删除只影响目标来源", testDeleteOnlyRemovesTarget),
        ("旧位置凭据迁移到新位置", testMigratesLegacyFile),
        ("新位置写失败时保留旧文件", testKeepsLegacyWhenNewWriteFails),
        ("新文件损坏时回退旧文件", testFallsBackToLegacyWhenNewCorrupt),
        ("新文件损坏且无旧文件时返回空", testCorruptNewWithoutLegacyReturnsEmpty),
        ("没有可写路径时报 storageUnavailable", testStorageUnavailable),
    ])

    private static func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mqb-\(name)-\(UUID().uuidString).json")
    }

    private static func write(_ all: [String: [String: String]], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url)
    }

    static func testSaveLoadRoundTripAndPermissions() throws {
        let file = temporaryFile("roundtrip")
        defer { try? FileManager.default.removeItem(at: file) }

        let provider = ProviderID("deepseek")
        try CredentialStore.save(
            ProviderCredential(["apiKey": "  sk-test  ", "empty": "   "]),
            for: provider,
            to: file,
            legacyURL: nil)

        let loaded = CredentialStore.loadCredential(for: provider, from: file, legacyURL: nil)
        try Expect.equal(loaded["apiKey"], "sk-test")
        try Expect.isNil(loaded["empty"])

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        try Expect.equal(permissions, 0o600)
    }

    static func testEmptyCredentialRemovesProvider() throws {
        let file = temporaryFile("empty")
        defer { try? FileManager.default.removeItem(at: file) }

        let a = ProviderID("qwen-token-plan")
        let b = ProviderID("cursor")
        try CredentialStore.save(ProviderCredential(["cookie": "a"]), for: a, to: file, legacyURL: nil)
        try CredentialStore.save(ProviderCredential(["cookie": "b"]), for: b, to: file, legacyURL: nil)
        try CredentialStore.save(ProviderCredential(), for: a, to: file, legacyURL: nil)

        try Expect.isTrue(CredentialStore.loadCredential(for: a, from: file, legacyURL: nil).allValues.isEmpty)
        try Expect.equal(
            CredentialStore.loadCredential(for: b, from: file, legacyURL: nil)["cookie"],
            "b")
    }

    static func testDeleteOnlyRemovesTarget() throws {
        let file = temporaryFile("delete")
        defer { try? FileManager.default.removeItem(at: file) }

        let a = ProviderID("deepseek")
        let b = ProviderID("cursor")
        try CredentialStore.save(ProviderCredential(["apiKey": "a"]), for: a, to: file, legacyURL: nil)
        try CredentialStore.save(ProviderCredential(["cookie": "b"]), for: b, to: file, legacyURL: nil)
        CredentialStore.delete(for: a, from: file, legacyURL: nil)

        try Expect.isTrue(CredentialStore.loadCredential(for: a, from: file, legacyURL: nil).allValues.isEmpty)
        try Expect.equal(
            CredentialStore.loadCredential(for: b, from: file, legacyURL: nil)["cookie"],
            "b")
    }

    static func testMigratesLegacyFile() throws {
        let legacy = temporaryFile("legacy")
        let new = temporaryFile("migrated")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: new)
        }
        try write(["cursor": ["cookie": "legacy-value"]], to: legacy)

        let loaded = CredentialStore.loadCredential(
            for: ProviderID("cursor"), from: new, legacyURL: legacy)
        try Expect.equal(loaded["cookie"], "legacy-value")
        try Expect.isTrue(FileManager.default.fileExists(atPath: new.path))
        try Expect.isTrue(!FileManager.default.fileExists(atPath: legacy.path))
    }

    static func testKeepsLegacyWhenNewWriteFails() throws {
        let legacy = temporaryFile("legacy-keep")
        let new = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("credentials.json")
        defer { try? FileManager.default.removeItem(at: legacy) }
        try write(["deepseek": ["apiKey": "keep-me"]], to: legacy)

        let loaded = CredentialStore.loadCredential(
            for: ProviderID("deepseek"), from: new, legacyURL: legacy)
        try Expect.equal(loaded["apiKey"], "keep-me")
        try Expect.isTrue(FileManager.default.fileExists(atPath: legacy.path))
        try Expect.isTrue(!FileManager.default.fileExists(atPath: new.path))
    }

    static func testFallsBackToLegacyWhenNewCorrupt() throws {
        let legacy = temporaryFile("legacy-corrupt")
        let new = temporaryFile("new-corrupt")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: new)
        }
        try write(["cursor": ["cookie": "from-legacy"]], to: legacy)
        try Data("not json".utf8).write(to: new)

        let loaded = CredentialStore.loadCredential(
            for: ProviderID("cursor"), from: new, legacyURL: legacy)
        try Expect.equal(loaded["cookie"], "from-legacy")
        // 迁移成功后会覆盖损坏的新文件并删掉旧文件。
        try Expect.isTrue(!FileManager.default.fileExists(atPath: legacy.path))
        let repaired = CredentialStore.loadCredential(
            for: ProviderID("cursor"), from: new, legacyURL: nil)
        try Expect.equal(repaired["cookie"], "from-legacy")
    }

    static func testCorruptNewWithoutLegacyReturnsEmpty() throws {
        let new = temporaryFile("corrupt-only")
        defer { try? FileManager.default.removeItem(at: new) }
        try Data("not json".utf8).write(to: new)

        try Expect.isTrue(
            CredentialStore.loadCredential(
                for: ProviderID("cursor"), from: new, legacyURL: nil
            ).allValues.isEmpty)
    }

    static func testStorageUnavailable() throws {
        try Expect.throwsError(try CredentialStore.persist([:], to: nil)) { error in
            guard case CredentialStore.CredentialError.storageUnavailable = error else {
                throw AssertionFailure(
                    message: "应为 storageUnavailable，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
        try Expect.throwsError(try CredentialStore.save(
            ProviderCredential(["a": "b"]),
            for: ProviderID("x"),
            to: nil,
            legacyURL: nil)) { error in
            guard case CredentialStore.CredentialError.storageUnavailable = error else {
                throw AssertionFailure(
                    message: "应为 storageUnavailable，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }
}

enum QuotaStorePolicyTests {
    static let suite = TestSuite("小组件发布策略", [
        ("缓存里未配置的来源会被丢掉", testDropsUnconfiguredCached),
        ("新数据里未配置的来源也会被丢掉", testDropsUnconfiguredFresh),
        ("抓取失败但凭据还在时保留旧快照", testKeepsCachedForConfiguredFailure),
        ("一个可用来源都没有时清空", testEmptyConfiguredClears),
        ("新数据覆盖旧值并按注册顺序排列", testFreshOverridesAndOrders),
    ])

    private static func snapshot(
        _ id: String,
        ratio: Double? = 0.5,
        updatedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            id: id,
            vendor: id,
            title: id,
            planName: nil,
            primaryTitle: ratio == nil ? nil : "每周",
            primaryRemainingRatio: ratio,
            primaryResetsAt: nil,
            balanceRemaining: nil,
            balanceUnit: nil,
            secondaryWindows: [],
            remainingDays: nil,
            updatedAt: updatedAt)
    }

    static func testDropsUnconfiguredCached() throws {
        let qwen = snapshot("qwen-token-plan")
        let deepseek = snapshot("deepseek")
        let cursor = snapshot("cursor")
        let merged = QuotaStore.widgetSnapshotsForPublish(
            disk: [qwen, deepseek, cursor],
            fresh: [],
            configuredIDs: ["deepseek", "cursor"])
        try Expect.equal(merged.map(\.id), ["deepseek", "cursor"])
    }

    static func testDropsUnconfiguredFresh() throws {
        let merged = QuotaStore.widgetSnapshotsForPublish(
            disk: [],
            fresh: [snapshot("qwen-token-plan"), snapshot("cursor")],
            configuredIDs: ["cursor"])
        try Expect.equal(merged.map(\.id), ["cursor"])
    }

    static func testKeepsCachedForConfiguredFailure() throws {
        let disk = snapshot("deepseek", ratio: 0.37)
        let merged = QuotaStore.widgetSnapshotsForPublish(
            disk: [disk],
            fresh: [],
            configuredIDs: ["deepseek"])
        try Expect.equal(merged.map(\.id), ["deepseek"])
        try Expect.equal(
            try Expect.notNil(try Expect.notNil(merged.first).primaryRemainingRatio),
            0.37, accuracy: 1e-9)
    }

    static func testEmptyConfiguredClears() throws {
        let cleared = QuotaStore.widgetSnapshotsForPublish(
            disk: [snapshot("qwen-token-plan")],
            fresh: [],
            configuredIDs: [])
        try Expect.equal(cleared, [])

        let alsoCleared = QuotaStore.widgetSnapshotsForPublish(
            disk: [snapshot("qwen-token-plan")],
            fresh: [snapshot("qwen-token-plan")],
            configuredIDs: [])
        try Expect.equal(alsoCleared, [])
    }

    static func testFreshOverridesAndOrders() throws {
        let staleDeepSeek = snapshot("deepseek", ratio: 0.1)
        let freshDeepSeek = snapshot("deepseek", ratio: 0.9)
        let cursor = snapshot("cursor")
        let merged = QuotaStore.widgetSnapshotsForPublish(
            disk: [staleDeepSeek],
            fresh: [cursor, freshDeepSeek],
            configuredIDs: ["deepseek", "cursor"])
        try Expect.equal(merged.map(\.id), ["deepseek", "cursor"])
        try Expect.equal(
            try Expect.notNil(try Expect.notNil(merged.first).primaryRemainingRatio),
            0.9, accuracy: 1e-9)
    }
}

enum QuotaFetcherSelectionTests {
    static let suite = TestSuite("小组件抓取来源过滤", [
        ("共享列表缺失时退回只看凭据", testFallsBackToConfigured),
        ("启用列表会过滤来源", testFiltersByEnabled),
        ("勾选 ids 会进一步过滤", testFiltersByIDs),
        ("空启用列表表示全部关闭", testEmptyEnabledSelectsNothing),
        ("启用但没凭据的来源不可用", testEnabledButUnconfigured),
    ])

    static func testFallsBackToConfigured() throws {
        let providers = QuotaFetcher.selectWidgetProviders(
            ids: nil,
            enabled: nil,
            configured: ["qwen-token-plan", "deepseek", "cursor"])
        try Expect.equal(
            providers.map(\.id.rawValue),
            ["qwen-token-plan", "deepseek", "cursor"])
    }

    static func testFiltersByEnabled() throws {
        let providers = QuotaFetcher.selectWidgetProviders(
            ids: nil,
            enabled: ["qwen-token-plan", "cursor"],
            configured: ["qwen-token-plan", "deepseek", "cursor"])
        try Expect.equal(providers.map(\.id.rawValue), ["qwen-token-plan", "cursor"])
    }

    static func testFiltersByIDs() throws {
        let providers = QuotaFetcher.selectWidgetProviders(
            ids: ["deepseek"],
            enabled: nil,
            configured: ["qwen-token-plan", "deepseek", "cursor"])
        try Expect.equal(providers.map(\.id.rawValue), ["deepseek"])
    }

    static func testEmptyEnabledSelectsNothing() throws {
        let providers = QuotaFetcher.selectWidgetProviders(
            ids: nil,
            enabled: [],
            configured: ["qwen-token-plan", "deepseek", "cursor"])
        try Expect.isTrue(providers.isEmpty)
    }

    static func testEnabledButUnconfigured() throws {
        let providers = QuotaFetcher.selectWidgetProviders(
            ids: nil,
            enabled: ["qwen-token-plan"],
            configured: ["cursor"])
        try Expect.isTrue(providers.isEmpty)
    }
}

enum SharedStoreExtraTests {
    static let suite = TestSuite("共享快照补充", [
        ("按可用来源过滤后合并", testMergeKeeping),
        ("缺 title 的旧快照仍可解码", testDecodesLegacySnapshot),
        ("千问快照过滤 Credits 并保留其余窗口", testQwenWidgetSnapshot),
        ("Cursor 的 USD 余额保留", testCursorWidgetSnapshot),
        ("余额型来源标记", testBalanceOnlyWidgetSnapshot),
        ("内容比较覆盖周期/天数等字段", testContentComparisonFields),
        ("损坏的启用列表按缺失处理", testCorruptEnabledList),
        ("损坏的完整缓存返回空", testCorruptSnapshotCache),
        ("快照文件可读写", testSnapshotFileRoundTrip),
        ("快照文件缺失/损坏返回空", testSnapshotFileMissingOrCorrupt),
    ])

    private static let date = Date(timeIntervalSince1970: 1_792_806_998)

    private static func snapshot(_ id: String, ratio: Double? = 0.5) -> WidgetSnapshot {
        WidgetSnapshot(
            id: id, vendor: id, title: id, planName: nil,
            primaryTitle: ratio == nil ? nil : "每周",
            primaryRemainingRatio: ratio, primaryResetsAt: nil,
            balanceRemaining: nil, balanceUnit: nil,
            secondaryWindows: [], remainingDays: nil, updatedAt: date)
    }

    private static func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mqb-\(name)-\(UUID().uuidString).json")
    }

    static func testMergeKeeping() throws {
        let merged = SharedStore.mergeSnapshots(
            cached: [snapshot("qwen-token-plan"), snapshot("cursor")],
            fresh: [snapshot("deepseek")],
            keeping: ["deepseek", "cursor"])
        try Expect.equal(merged.map(\.id), ["deepseek", "cursor"])

        try Expect.equal(
            SharedStore.mergeSnapshots(
                cached: [snapshot("deepseek")],
                fresh: [],
                keeping: []),
            [])
        try Expect.equal(
            SharedStore.mergeSnapshots(
                cached: [snapshot("deepseek")],
                fresh: [],
                keeping: ["deepseek"]).map(\.id),
            ["deepseek"])
    }

    static func testDecodesLegacySnapshot() throws {
        let json = """
        [{"id":"deepseek","vendor":"DeepSeek","secondaryWindows":[],
          "updatedAt":"2026-10-31T04:08:07Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WidgetSnapshot].self, from: Data(json.utf8))
        let snapshot = try Expect.notNil(decoded.first)
        try Expect.isNil(snapshot.title)
        try Expect.equal(snapshot.displayTitle, "DeepSeek")
        try Expect.isNil(snapshot.primaryRemainingRatio)
    }

    static func testQwenWidgetSnapshot() throws {
        let qwen = QuotaSnapshot(
            planName: "Pro 专业版",
            status: "VALID",
            windows: [
                QuotaWindow(id: "5h", title: "每 5 小时", usedRatio: 0.01, resetsAt: date, totalQuota: 12000, unit: "Credits"),
                QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.3, resetsAt: date, totalQuota: 40000, unit: "Credits"),
                QuotaWindow(id: "monthly", title: "每月", usedRatio: 0.4, resetsAt: date, totalQuota: 50000, unit: "Credits"),
            ],
            balance: CreditBalance(remaining: 18_320, total: 20_000, unit: "Credits"),
            remainingDays: 29,
            updatedAt: date)
        let widget = qwen.widgetSnapshot(
            id: QwenTokenPlanProvider.metadata.id,
            vendor: "通义千问",
            title: "通义千问 Token Plan")
        try Expect.equal(widget.id, "qwen-token-plan")
        try Expect.equal(widget.primaryTitle, "每月")
        try Expect.equal(
            try Expect.notNil(widget.primaryRemainingRatio),
            0.6, accuracy: 1e-9)
        try Expect.equal(widget.primaryResetsAt, date)
        try Expect.equal(widget.secondaryWindows.map(\.id), ["5h", "weekly"])
        try Expect.isNil(widget.balanceRemaining)
        try Expect.equal(widget.remainingDays, 29)
        try Expect.equal(widget.title, "通义千问 Token Plan")
    }

    static func testCursorWidgetSnapshot() throws {
        let cursor = QuotaSnapshot(
            planName: "Premium",
            windows: [QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.13, resetsAt: date, unit: "USD")],
            balance: CreditBalance(remaining: 26, unit: "USD"),
            updatedAt: date)
        let widget = cursor.widgetSnapshot(id: CursorProvider.metadata.id, vendor: "Cursor")
        try Expect.equal(widget.primaryTitle, "每周")
        try Expect.equal(try Expect.notNil(widget.primaryRemainingRatio), 0.87, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(widget.balanceRemaining), 26, accuracy: 1e-9)
        try Expect.equal(widget.balanceUnit, "USD")
        try Expect.isTrue(!widget.isBalanceOnly)
    }

    static func testBalanceOnlyWidgetSnapshot() throws {
        let deepseek = QuotaSnapshot(
            isAvailable: true,
            windows: [],
            balance: CreditBalance(remaining: 8.47, unit: "CNY"),
            updatedAt: date)
        let widget = deepseek.widgetSnapshot(id: DeepSeekProvider.metadata.id, vendor: "DeepSeek")
        try Expect.isNil(widget.primaryRemainingRatio)
        try Expect.equal(try Expect.notNil(widget.balanceRemaining), 8.47, accuracy: 1e-9)
        try Expect.equal(widget.balanceUnit, "CNY")
        try Expect.isTrue(widget.isBalanceOnly)
    }

    static func testContentComparisonFields() throws {
        let base = snapshot("cursor")
        var same = base
        same.updatedAt = date.addingTimeInterval(3600)
        try Expect.isTrue(SharedStore.snapshotsHaveSameContent([base], [same]))

        var changedPlan = same
        changedPlan.planName = "Premium"
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], [changedPlan]))

        var changedSecondary = same
        changedSecondary.secondaryWindows = [
            WidgetWindow(id: "weekly", title: "每周", remainingRatio: 0.5, resetsAt: nil),
        ]
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], [changedSecondary]))

        var changedDays = same
        changedDays.remainingDays = 3
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], [changedDays]))

        var changedReset = same
        changedReset.primaryResetsAt = date.addingTimeInterval(60)
        try Expect.isTrue(!SharedStore.snapshotsHaveSameContent([base], [changedReset]))
    }

    static func testCorruptEnabledList() throws {
        let url = temporaryFile("enabled-corrupt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        try Expect.isNil(SharedStore.loadEnabledProviderIDs(from: url))
    }

    static func testCorruptSnapshotCache() throws {
        let url = temporaryFile("quota-cache-corrupt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        try Expect.isTrue(SnapshotCache.load(from: url).isEmpty)
        try Expect.isTrue(SnapshotCache.load(from: nil).isEmpty)
        SnapshotCache.save([:], to: nil)
    }

    static func testSnapshotFileRoundTrip() throws {
        let url = temporaryFile("snapshot-roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(
            id: "cursor",
            vendor: "Cursor",
            title: "Cursor 订阅用量",
            planName: "Premium",
            primaryTitle: "每周",
            primaryRemainingRatio: 0.87,
            primaryResetsAt: date,
            balanceRemaining: 0,
            balanceUnit: "USD",
            secondaryWindows: [
                WidgetWindow(id: "monthly", title: "每月", remainingRatio: 0.5, resetsAt: date),
            ],
            remainingDays: 3,
            updatedAt: date)
        SharedStore.save([snapshot], to: url)
        let loaded = SharedStore.loadSnapshots(from: url)
        try Expect.equal(loaded, [snapshot])
    }

    static func testSnapshotFileMissingOrCorrupt() throws {
        try Expect.equal(SharedStore.loadSnapshots(from: nil), [])
        try Expect.equal(
            SharedStore.loadSnapshots(from: temporaryFile("snapshot-missing")),
            [])

        let corrupt = temporaryFile("snapshot-corrupt")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try Data("not json".utf8).write(to: corrupt)
        try Expect.equal(SharedStore.loadSnapshots(from: corrupt), [])
        SharedStore.save([], to: nil)
    }
}

enum QwenExtraTests {
    static let suite = TestSuite("QwenTokenPlan · 补充", [
        ("每月窗口和总额", testMonthlyWindowAndTotals),
        ("套餐档位名称映射", testPlanNameMappings),
        ("snake_case / plan_name 也能取档位", testPlanCodeVariants),
        ("增值包没有剩余 Credits 时返回 nil", testAddonWithoutRemaining),
        ("订阅状态和到期时间", testExpiresAtAndStatus),
        ("站点缺省和未知值退回中国站", testRegionHelper),
    ])

    private static func makeSnapshot(
        usage: Any? = nil,
        subscription: Any? = nil,
        quota: Any? = nil,
        addon: Any? = nil
    ) throws -> QuotaSnapshot {
        try QwenTokenPlanProvider.makeSnapshot(
            usagePayload: try usage ?? jsonObject(QwenTokenPlanParsingTests.usageJSON),
            subscriptionPayload: subscription,
            quotaConfigPayload: quota,
            addonPayload: addon,
            region: .chinaMainland)
    }

    static func testMonthlyWindowAndTotals() throws {
        let usage = try jsonObject("""
        { "data": { "data": { "data": {
            "per1MonthPercentage": 0.4,
            "per1MonthResetTime": 1785234900000 } } } }
        """)
        let subscription = try jsonObject("""
        { "data": { "data": { "data": {
            "specCode": "standard", "status": "VALID" } } } }
        """)
        let quota = try jsonObject("""
        { "data": { "data": { "data": {
            "standard": { "monthly": 50000 } } } } }
        """)
        let snapshot = try makeSnapshot(usage: usage, subscription: subscription, quota: quota)
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])
        let monthly = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(monthly.usedRatio, 0.4, accuracy: 1e-9)
        try Expect.equal(monthly.remainingRatio, 0.6, accuracy: 1e-9)
        try Expect.equal(try Expect.notNil(monthly.totalQuota), 50_000)
        try Expect.equal(monthly.resetsAt, Date(timeIntervalSince1970: 1_785_234_900))
        try Expect.equal(snapshot.planName, "Standard 标准版")
    }

    static func testPlanNameMappings() throws {
        let mappings: [(String, String)] = [
            ("lite", "Lite 轻量版"),
            ("essential", "Essential 基础版"),
            ("standard", "Standard 标准版"),
            ("pro", "Pro 专业版"),
            ("max", "Max 尊享版"),
            ("mystery", "Mystery"),
        ]
        for (code, expected) in mappings {
            let subscription = try jsonObject(#"{"specCode":"\#(code)"}"#)
            let snapshot = try makeSnapshot(subscription: subscription)
            try Expect.equal(snapshot.planName, expected, "档位 \(code)")
        }
    }

    static func testPlanCodeVariants() throws {
        let snake = try makeSnapshot(
            subscription: try jsonObject(#"{"data":{"spec_code":"pro"}}"#))
        try Expect.equal(snake.planName, "Pro 专业版")

        let planName = try makeSnapshot(
            subscription: try jsonObject(#"{"plan_name":"Max"}"#))
        try Expect.equal(planName.planName, "Max 尊享版")

        let camel = try makeSnapshot(
            subscription: try jsonObject(#"{"planName":"Essential"}"#))
        try Expect.equal(camel.planName, "Essential 基础版")
    }

    static func testAddonWithoutRemaining() throws {
        let addon = try jsonObject(#"{"totalCredits": 100}"#)
        let snapshot = try makeSnapshot(addon: addon)
        try Expect.isNil(snapshot.balance)
    }

    static func testExpiresAtAndStatus() throws {
        let subscription = try jsonObject("""
        { "data": { "data": { "data": {
            "specCode": "pro",
            "status": "EXPIRED",
            "endTime": 1787328000000,
            "remainingDays": 0 } } } }
        """)
        let snapshot = try makeSnapshot(subscription: subscription)
        try Expect.equal(snapshot.status, "EXPIRED")
        try Expect.equal(snapshot.expiresAt, Date(timeIntervalSince1970: 1_787_328_000))
        try Expect.equal(snapshot.remainingDays, 0)
    }

    static func testRegionHelper() throws {
        try Expect.equal(
            QwenTokenPlanProvider.region(for: ProviderCredential()),
            .chinaMainland)
        try Expect.equal(
            QwenTokenPlanProvider.region(for: ProviderCredential(["region": "intl"])),
            .international)
        try Expect.equal(
            QwenTokenPlanProvider.region(for: ProviderCredential(["region": "unknown"])),
            .chinaMainland)
    }
}

enum CursorExtraTests {
    static let suite = TestSuite("Cursor · 补充", [
        ("Premium 明确 monthly 时生成月窗口", testPremiumExplicitMonthly),
        ("周期窗口按 8 天边界判断", testCycleWindowBoundary),
        ("从展示文案提取百分比", testPercentExtraction),
        ("周缓存无重置时间时最多保留 7 天", testWeeklyCacheEntryValidity),
        ("planUsage 百分比也算可用", testHasPlanPercentPlanUsage),
        ("错误对象/空壳不是权威 Credits", testCreditsAuthoritativeErrorObject),
        ("非权威余额且无缓存时保持 0 且不写缓存", testCreditsCacheNonAuthoritativeWithoutCache),
        ("周期字段支持数字和字符串", testWeeklyPlanNumericPeriods),
        ("顶层数组形式的 grants 也能解析", testCreditGrantsTopLevelArray),
        ("嵌套 grants 进入余额", testMakeSnapshotCreditsFromNestedGrants),
        ("负数赠送额度不计入", testNegativeGrantIgnored),
    ])

    static func testPremiumExplicitMonthly() throws {
        let summary = try jsonObject("""
        { "membershipType": "premium",
          "billingCycleStart": "2026-10-01T00:00:00.000Z",
          "billingCycleEnd": "2026-11-01T00:00:00.000Z",
          "individualUsage": { "plan": { "enabled": true, "used": 100, "limit": 1000 } } }
        """)
        let period = try jsonObject("""
        { "billingCycleStart": "1790812800000",
          "billingCycleEnd": "1793491200000",
          "planUsage": { "totalPercentUsed": 10 } }
        """)
        let planInfo = try jsonObject("""
        { "planInfo": {
            "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_MONTHLY",
            "includedUsageResetsAt": 1793491200000 } }
        """)
        let snapshot = try CursorProvider.makeSnapshot(
            summaryPayload: summary,
            periodPayload: period,
            planInfoPayload: planInfo)
        try Expect.equal(snapshot.windows.map(\.id), ["monthly"])
        let window = try Expect.notNil(snapshot.primaryWindow)
        try Expect.equal(window.title, "每月")
        try Expect.equal(window.usedRatio, 0.1, accuracy: 1e-9)
    }

    static func testCycleWindowBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_790_812_800)
        try Expect.equal(
            CursorProvider.cycleWindow(start: start, end: start.addingTimeInterval(8 * 86_400)).id,
            "weekly")
        try Expect.equal(
            CursorProvider.cycleWindow(start: start, end: start.addingTimeInterval(8 * 86_400 + 1)).id,
            "monthly")
        try Expect.equal(CursorProvider.cycleWindow(start: nil, end: nil).id, "monthly")
    }

    static func testPercentExtraction() throws {
        try Expect.equal(
            CursorProvider.percent(in: "You've used 3.5% of your included usage"),
            0.035)
        try Expect.equal(CursorProvider.percent(in: "0%"), 0)
        try Expect.isNil(CursorProvider.percent(in: "no percent here"))
        try Expect.isNil(CursorProvider.percent(in: 42))
    }

    static func testWeeklyCacheEntryValidity() throws {
        let now = Date(timeIntervalSince1970: 1_792_806_998)
        let recent = CursorProvider.WeeklyCache.Entry(
            id: "weekly", title: "每周", usedRatio: 0.1,
            resetsAt: nil, totalQuota: nil, unit: "USD",
            savedAt: now.addingTimeInterval(-6 * 86_400))
        try Expect.isTrue(CursorProvider.WeeklyCache.isValid(recent, now: now))

        var old = recent
        old.savedAt = now.addingTimeInterval(-8 * 86_400)
        try Expect.isTrue(!CursorProvider.WeeklyCache.isValid(old, now: now))

        var futureReset = recent
        futureReset.resetsAt = now.addingTimeInterval(86_400)
        try Expect.isTrue(CursorProvider.WeeklyCache.isValid(futureReset, now: now))

        var pastReset = recent
        pastReset.resetsAt = now.addingTimeInterval(-1)
        try Expect.isTrue(!CursorProvider.WeeklyCache.isValid(pastReset, now: now))
    }

    static func testHasPlanPercentPlanUsage() throws {
        try Expect.isTrue(CursorProvider.hasPlanPercent(
            try jsonObject(#"{"planUsage":{"totalPercentUsed":3.5}}"#)))
        try Expect.isTrue(CursorProvider.hasPlanPercent(
            try jsonObject(#"{"autoModelSelectedDisplayMessage":"You've used 3% of your included total usage"}"#)))
        try Expect.isTrue(!CursorProvider.hasPlanPercent(try jsonObject("{}")))
    }

    static func testCreditsAuthoritativeErrorObject() throws {
        try Expect.isTrue(!CursorProvider.creditsAreAuthoritative(
            grantsPayload: try jsonObject(#"{"error":"boom"}"#),
            stripePayload: nil))
        try Expect.isTrue(!CursorProvider.creditsAreAuthoritative(
            grantsPayload: try jsonObject("{}"),
            stripePayload: try jsonObject(#"{"customerBalance":0}"#)))
        try Expect.isTrue(CursorProvider.creditsAreAuthoritative(
            grantsPayload: try jsonObject(#"{"grants":[]}"#),
            stripePayload: nil))
    }

    static func testCreditsCacheNonAuthoritativeWithoutCache() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-credits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_792_806_998)
        let snapshot = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", title: "每周", usedRatio: 0.1, unit: "USD")],
            balance: CreditBalance(remaining: 0, unit: "USD"),
            updatedAt: now)
        let result = CursorProvider.CreditsCache.apply(
            to: snapshot, now: now, url: url, authoritative: false)
        try Expect.equal(try Expect.notNil(result.balance).remaining, 0, accuracy: 1e-9)
        try Expect.isTrue(!FileManager.default.fileExists(atPath: url.path))
    }

    static func testWeeklyPlanNumericPeriods() throws {
        try Expect.isTrue(CursorProvider.weeklyPlan(
            try jsonObject(#"{"includedUsagePeriod":2}"#), membershipType: nil).weekly)
        try Expect.isTrue(!CursorProvider.weeklyPlan(
            try jsonObject(#"{"includedUsagePeriod":1}"#), membershipType: nil).weekly)
        try Expect.isTrue(CursorProvider.weeklyPlan(
            try jsonObject(#"{"includedUsagePeriod":"WEEKLY"}"#), membershipType: nil).weekly)
        try Expect.isTrue(!CursorProvider.weeklyPlan(
            try jsonObject(#"{"includedUsagePeriod":"MONTHLY"}"#), membershipType: nil).weekly)
        try Expect.isTrue(CursorProvider.weeklyPlan(nil, membershipType: "premium").weekly)
        try Expect.isTrue(CursorProvider.weeklyPlan(
            try jsonObject("{}"), membershipType: "premium").weekly)
        try Expect.isTrue(!CursorProvider.isWeeklyMembership(nil))
    }

    static func testCreditGrantsTopLevelArray() throws {
        let grants = try jsonObject(#"[{"remainingCents":100}]"#)
        let parsed = try Expect.notNil(CursorProvider.creditGrants(in: grants))
        try Expect.equal(parsed.count, 1)
    }

    static func testMakeSnapshotCreditsFromNestedGrants() throws {
        let summary = try jsonObject(CursorTests.summaryJSON)
        let grants = try jsonObject("""
        { "data": { "grants": [ { "remainingCents": 1234 } ] } }
        """)
        let snapshot = try CursorProvider.makeSnapshot(
            summaryPayload: summary,
            grantsPayload: grants)
        try Expect.equal(try Expect.notNil(snapshot.balance).remaining, 12.34, accuracy: 1e-9)
    }

    static func testNegativeGrantIgnored() throws {
        let grants = try jsonObject(#"[{"remainingCents":-100}]"#)
        let balance = try Expect.notNil(
            CursorProvider.accountCredits(grantsPayload: grants, stripePayload: nil))
        try Expect.equal(balance.remaining, 0, accuracy: 1e-9)
    }
}

enum AliyunErrorTests {
    static let suite = TestSuite("阿里云网关错误分类", [
        ("成功的响应不抛错", testSuccessDoesNotThrow),
        ("successResponse=false 分类为会话过期", testTopLevelFailureIsSessionExpired),
        ("嵌套 AccessDenied 分类为凭据无效", testNestedFailureIsInvalidCredential),
        ("httpStatus 非 200 抛业务错误", testHttpStatusFailureIsAPIError),
        ("未知业务错误带原文", testGenericFailure),
    ])

    static func testSuccessDoesNotThrow() throws {
        try AliyunConsoleGatewayClient.throwIfError(try jsonObject("""
        { "successResponse": true,
          "data": { "DataV2": { "success": true, "httpStatus": 200 } } }
        """))
    }

    static func testTopLevelFailureIsSessionExpired() throws {
        try Expect.throwsError(try AliyunConsoleGatewayClient.throwIfError(
            try jsonObject(#"{"successResponse":false,"errorCode":"NotLogined"}"#))) { error in
            guard case QuotaError.sessionExpired = error else {
                throw AssertionFailure(
                    message: "应为 sessionExpired，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }

    static func testNestedFailureIsInvalidCredential() throws {
        try Expect.throwsError(try AliyunConsoleGatewayClient.throwIfError(
            try jsonObject(#"{"data":{"success":false,"errorMsg":"AccessDenied"}}"#))) { error in
            guard case QuotaError.invalidCredential = error else {
                throw AssertionFailure(
                    message: "应为 invalidCredential，实际 \(error)",
                    file: #filePath, line: #line)
            }
        }
    }

    static func testHttpStatusFailureIsAPIError() throws {
        try Expect.throwsError(try AliyunConsoleGatewayClient.throwIfError(
            try jsonObject(#"{"data":{"httpStatus":500,"message":"boom"}}"#))) { error in
            guard case let QuotaError.api(message) = error else {
                throw AssertionFailure(
                    message: "应为 api，实际 \(error)",
                    file: #filePath, line: #line)
            }
            try Expect.equal(message, "boom")
        }
    }

    static func testGenericFailure() throws {
        try Expect.throwsError(try AliyunConsoleGatewayClient.throwIfError(
            try jsonObject(#"{"successResponse":false,"errorCode":"Something","errorMsg":"oops"}"#))) { error in
            guard case let QuotaError.api(message) = error else {
                throw AssertionFailure(
                    message: "应为 api，实际 \(error)",
                    file: #filePath, line: #line)
            }
            try Expect.equal(message, "oops")
        }
    }
}

enum ProviderModelTests {
    static let suite = TestSuite("Provider 模型补充", [
        ("ProviderRegistry 顺序/去重/查找", testRegistry),
        ("凭据字段裁剪与 allValues", testCredentialTrimming),
        ("ProviderMetadata 解析器缺失时退回静态值", testMetadataFallback),
        ("QuotaError 都有面向用户的文案", testErrorDescriptions),
        ("JSONSearch containingAnyOf / 字符串 / 数字", testJSONSearchExtras),
        ("DeepSeek 空余额数组/非法金额/缺字段报错", testDeepSeekEdgeCases),
        ("DeepSeek 元数据注册", testDeepSeekMetadata),
        ("主窗口没有周/月时取第一个，空数组为 nil", testPrimaryWindowFallbacks),
    ])

    static func testRegistry() throws {
        try Expect.equal(
            ProviderRegistry.all.map(\.id.rawValue),
            ["qwen-token-plan", "deepseek", "cursor"])
        try Expect.equal(Set(ProviderRegistry.all.map(\.id)).count, 3)
        try Expect.equal(
            ProviderRegistry.descriptor(for: ProviderID("cursor"))?.metadata.vendor,
            "Cursor")
        try Expect.isNil(ProviderRegistry.descriptor(for: ProviderID("nope")))
    }

    static func testCredentialTrimming() throws {
        let credential = ProviderCredential(["apiKey": "  sk-1  ", "blank": "   "])
        try Expect.equal(credential["apiKey"], "sk-1")
        try Expect.isNil(credential["blank"])
        try Expect.equal(credential.allValues, ["apiKey": "sk-1"])
        try Expect.isTrue(ProviderCredential(["blank": "   "]).allValues.isEmpty)

        let fields = [
            CredentialField(id: "apiKey", title: "API Key"),
            CredentialField(id: "region", title: "站点", isOptional: true),
        ]
        try Expect.isTrue(credential.isComplete(for: fields))
        try Expect.isTrue(!ProviderCredential(["region": "cn"]).isComplete(for: fields))
        try Expect.isTrue(ProviderCredential().isEmpty)
    }

    static func testMetadataFallback() throws {
        let baseURL = try Expect.notNil(URL(string: "https://example.com"))
        let spec = WebLoginSpec(
            url: baseURL, cookieName: "c", targetFieldID: "f", hint: "h")
        let metadata = ProviderMetadata(
            id: ProviderID("x"),
            vendor: "V",
            plan: "P",
            summary: "S",
            consoleURL: baseURL,
            consoleURLResolver: { _ in nil },
            webLogin: spec,
            webLoginResolver: { _ in nil })
        try Expect.equal(metadata.consoleURL(for: ProviderCredential()), baseURL)
        try Expect.equal(metadata.webLogin(for: ProviderCredential())?.cookieName, "c")

        let otherURL = try Expect.notNil(URL(string: "https://other.example.com"))
        let overridden = ProviderMetadata(
            id: ProviderID("y"),
            vendor: "V",
            plan: "P",
            summary: "S",
            consoleURL: baseURL,
            consoleURLResolver: { _ in otherURL })
        try Expect.equal(overridden.consoleURL(for: ProviderCredential()), otherURL)
        try Expect.isNil(overridden.webLogin(for: ProviderCredential()))
    }

    static func testErrorDescriptions() throws {
        let errors: [QuotaError] = [
            .missingCredential("API Key"),
            .sessionExpired,
            .invalidCredential("bad"),
            .network("offline"),
            .decoding("bad json"),
            .api("boom"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            try Expect.isTrue(!text.isEmpty, "\(error) 缺少文案")
        }
    }

    static func testJSONSearchExtras() throws {
        let payload = try jsonObject("""
        { "outer": [ { "inner": { "per1WeekPercentage": 0.5 } } ] }
        """)
        let found = try Expect.notNil(JSONSearch.findObject(
            containingAnyOf: ["per1WeekPercentage", "notThere"], in: payload))
        try Expect.equal(JSONSearch.number(found["per1WeekPercentage"]), 0.5)
        try Expect.isNil(JSONSearch.findObject(containingAllOf: [], in: payload))

        try Expect.equal(JSONSearch.number(NSNumber(value: 3)), 3)
        try Expect.equal(JSONSearch.string("  value  "), "value")
        try Expect.isNil(JSONSearch.string("   "))
        try Expect.equal(JSONSearch.string(42), "42")
        try Expect.equal(
            JSONSearch.findValue(forKeys: ["per1WeekPercentage"], in: payload) as? Double,
            0.5)
    }

    static func testDeepSeekEdgeCases() throws {
        let empty = Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)
        try expectDecoding(try DeepSeekProvider.makeSnapshot(from: empty))

        let badAmount = Data("""
        { "is_available": true, "balance_infos": [
            {"currency":"CNY","total_balance":"abc"} ] }
        """.utf8)
        try expectDecoding(try DeepSeekProvider.makeSnapshot(from: badAmount))

        let missingFlag = Data("""
        { "balance_infos": [
            {"currency":"CNY","total_balance":"1.00"} ] }
        """.utf8)
        try expectDecoding(try DeepSeekProvider.makeSnapshot(from: missingFlag))
    }

    static func testDeepSeekMetadata() throws {
        try Expect.equal(DeepSeekProvider.metadata.id.rawValue, "deepseek")
        try Expect.equal(DeepSeekProvider.metadata.vendor, "DeepSeek")
        try Expect.isNil(DeepSeekProvider.metadata.webLogin)
        try Expect.equal(DeepSeekProvider.credentialFields.first?.id, "apiKey")
        try Expect.equal(CurrencySymbol.prefix(for: "JPY"), "¥")
    }

    static func testPrimaryWindowFallbacks() throws {
        let onlyFiveHour = QuotaSnapshot(windows: [
            QuotaWindow(id: "5h", title: "每 5 小时", usedRatio: 0.1),
        ])
        try Expect.equal(onlyFiveHour.primaryWindow?.id, "5h")
        try Expect.isNil(QuotaSnapshot(windows: []).primaryWindow)
    }

    private static func expectDecoding<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try Expect.throwsError(try expression(), { error in
            guard case QuotaError.decoding = error else {
                throw AssertionFailure(
                    message: "应为 decoding，实际 \(error)",
                    file: "\(file)", line: line)
            }
        }, file: file, line: line)
    }
}
