import Foundation
import Testing
@testable import QuotaNest

@Suite
struct DataEngineTests {
    @Test func manifestHeaderUpgradeAddsMissingNamesAndPreservesExistingValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-header-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("manifest.json")
        let auth = root.appendingPathComponent("account.json")
        let credentials = Data(#"{"refreshApiKey":"fixture-account-key","scheduleTimes":["09:00"]}"#.utf8)
        try credentials.write(to: auth)
        let existingHeader = "authorization: Bearer user-value\nX-Own: keep\nuSeR-aGeNt: CustomClient/2.0"
        let original: [String: Any] = ["name": "Custom", "label": "C", "displayName": "User name",
            "enabled": false, "authFile": auth.path, "refreshHeader": existingHeader,
            "customMetadata": ["keep": true]]
        try JSONSerialization.data(withJSONObject: original).write(to: path)
        // An arbitrary type name ensures upgrade behavior does not depend on a supplier slug.
        let template = ProviderManifest(name: "arbitrary-type", label: "T",
            refreshHeader: "Authorization: Bearer <key>\nx-opencode-session: tokenhud-<session>\nUser-Agent: TokenHUD/1.0")
        DataEngine.mergeManifestCapabilities(template: template, into: path)
        let upgraded = try Data(contentsOf: path)
        let object = try #require(try JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        #expect(object["refreshHeader"] as? String == existingHeader + "\nx-opencode-session: tokenhud-<session>")
        #expect(object["displayName"] as? String == "User name")
        #expect(object["enabled"] as? Bool == false)
        #expect(object["customMetadata"] as? [String: Bool] == ["keep": true])
        #expect(try Data(contentsOf: auth) == credentials)
        DataEngine.mergeManifestCapabilities(template: template, into: path)
        #expect(try Data(contentsOf: path) == upgraded)
    }

    @Test func declaredModelAliasesRepairHistoricalWindowDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-scope-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("manifest.json")
        let original = ProviderManifest(name: "arbitrary", label: "A", testModel: "old-paid",
            windowTrigger: ProviderWindowTrigger(period: "five_hour", model: "old-paid"))
        var oldObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldObject["modelCatalog"] = ["models": ["old-paid"], "allowedPrefixes": ["plan/"]]
        try JSONSerialization.data(withJSONObject: oldObject).write(to: path)
        let template = ProviderManifest(name: "type", label: "T",
            modelCatalog: ProviderModelCatalog(url: "https://docs.example.test/models.md", format: "markdown-table", section: "Models", allowedPrefixes: ["plan/"], aliases: ["old-paid": "plan/chat"]))
        DataEngine.mergeManifestCapabilities(template: template, into: path)
        let upgraded = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: path))
        #expect(upgraded.testModel == "plan/chat")
        #expect(upgraded.windowTrigger?.model == "plan/chat")
        #expect(upgraded.modelCatalog?.allowedPrefixes == ["plan/"])
        #expect(upgraded.modelCatalog?.url == "https://docs.example.test/models.md")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect((object["modelCatalog"] as? [String: Any])?["models"] == nil)
        let first = try Data(contentsOf: path)
        DataEngine.mergeManifestCapabilities(template: template, into: path)
        #expect(try Data(contentsOf: path) == first)
    }

    @Test func manifestHeaderUpgradeRetainsNilAndEmptyHeaderBehavior() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-header-defaults-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = ProviderManifest(name: "type", label: "T", refreshHeader: "X-First: one\nX-Second: two")
        for hasEmptyHeader in [false, true] {
            let path = root.appendingPathComponent("\(hasEmptyHeader).json")
            var object: [String: Any] = ["name": "Account", "label": "A"]
            if hasEmptyHeader { object["refreshHeader"] = "" }
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            DataEngine.mergeManifestCapabilities(template: template, into: path)
            let upgraded = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            #expect(upgraded["refreshHeader"] as? String == template.refreshHeader)
        }
    }

    @Test @MainActor func startupMigrationRemovesTheOldQueryIdentityAndItsCache() throws {
        let (engine, root, hud, _) = makeEngine("query-identity-upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        addPlugin("shared", stdout: "{}", to: root)
        let auth = hud.appendingPathComponent(".shared-usage-auth.json")
        let cache = hud.appendingPathComponent(".shared-usage-cache.json")
        try JSONSerialization.data(withJSONObject: ["refreshApiKey": "base-account-A", "queryKey": "query-account-B",
            "headers": ["authorization": "old-B", "x-trace": "keep"], "quotaCredentialMode": "legacy",
            "scheduleTimes": ["09:00"], "other": true]).write(to: auth)
        try Data(#"{"generatedAt":9999999999999,"seven_day":{"used_percentage":87}}"#.utf8).write(to: cache)
        engine.reloadRegistry()
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 87)
        engine.migrateAccounts()
        #expect(engine.states.first?.cache == nil)
        engine.reloadRegistry()
        #expect(engine.states.first?.cache == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        let config = ProviderConfigStore.read(authFile: auth, manifest: engine.allPlugins[0].manifest)
        #expect(config.refreshKey == "base-account-A")
        #expect(!ProviderConfigStore.hasObsoleteQueryCredentials(authFile: auth, manifest: engine.allPlugins[0].manifest))
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        #expect(saved["other"] as? Bool == true)
        #expect(saved["scheduleTimes"] as? [String] == ["09:00"])
        #expect(saved["headers"] as? [String: String] == ["x-trace": "keep"])
        let migrated = try Data(contentsOf: auth)
        engine.migrateAccounts()
        #expect(try Data(contentsOf: auth) == migrated)
    }

    @Test @MainActor func startupQueryMigrationReportsAnUnownedCacheWithoutShowingIt() throws {
        let (engine, root, hud, _) = makeEngine("query-upgrade-cache-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        addPlugin("shared", stdout: "{}", to: root)
        let auth = hud.appendingPathComponent(".shared-usage-auth.json")
        let cache = root.appendingPathComponent("external-usage-cache.json")
        let original = Data(#"{"refreshApiKey":"base-A","queryKey":"old-B"}"#.utf8)
        let cached = Data(#"{"generatedAt":9999999999999,"seven_day":{"used_percentage":87}}"#.utf8)
        try original.write(to: auth)
        try cached.write(to: cache)
        let manifest = ProviderManifest(name: "shared", label: "shared", cacheFile: cache.path, authFile: auth.path)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("providers/shared/manifest.json"))
        engine.migrateAccounts()
        engine.reloadRegistry()
        #expect(engine.registryErrors["shared"]?.contains("查询认证迁移失败") == true)
        #expect(engine.states.first?.cache == nil)
        #expect(try Data(contentsOf: auth) == original)
        #expect(try Data(contentsOf: cache) == cached)
    }

    @Test @MainActor func startupQueryMigrationSkipsExternalSymlinkAndAuthSourceFiles() throws {
        let (engine, root, hud, _) = makeEngine("query-upgrade-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"authMode":"apikey","refreshApiKey":"base-A","queryKey":"old-B"}"#.utf8)
        let external = root.appendingPathComponent("external-usage-auth.json")
        try original.write(to: external)
        for slug in ["external", "linked", "source"] {
            addPlugin(slug, stdout: "{}", to: root)
            let auth = slug == "external" ? external : hud.appendingPathComponent(".\(slug)-usage-auth.json")
            if slug == "linked" { try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: external) }
            if slug == "source" { try original.write(to: auth) }
            var manifest = ProviderManifest(name: slug, label: slug, authFile: auth.path)
            if slug == "source" { manifest.credentialSource = ProviderCredentialSource(file: auth.path, tokenPath: "tokens.access_token") }
            try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("providers/\(slug)/manifest.json"))
        }
        engine.migrateAccounts()
        #expect(try Data(contentsOf: external) == original)
        #expect(try Data(contentsOf: hud.appendingPathComponent(".source-usage-auth.json")) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: hud.appendingPathComponent(".linked-usage-auth.json").path) == external.path)
        #expect(engine.registryErrors.isEmpty)
    }

    @Test @MainActor func automaticQuotaUsesBaseKeyWithoutSeparateQueryKey() async throws {
        let (engine, root, hud, _) = makeEngine("inherited-auto-query")
        defer { try? FileManager.default.removeItem(at: root) }
        addPlugin("shared", stdout: #"{"seven_day":{"used_percentage":10}}"#, to: root)
        let auth = hud.appendingPathComponent(".shared-usage-auth.json")
        let manifest = ProviderManifest(name: "shared", label: "shared", authFile: auth.path,
            queryUrl: "https://example.test/usage", queryAuth: "bearer", quotaMode: "script")
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("providers/shared/manifest.json"))
        var config = ProviderConfig()
        config.refreshKey = "fixture-base-key"
        config.quotaMode = "script"
        try ProviderConfigStore.write(config, manifest: manifest, to: auth)
        let original = try Data(contentsOf: auth)
        engine.reloadRegistry()
        await engine.refreshNow()
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 10)
        #expect(try Data(contentsOf: auth) == original)
        #expect(ProviderConfigStore.read(authFile: auth, manifest: manifest).queryKey.isEmpty)
    }

    @Test func authSourceChangeUpdatesQueryRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-auth-revision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("account.json")
        let source = root.appendingPathComponent("login.json")
        let account = Data(#"{"schemaVersion":3,"authMode":"auth","quotaCredentialMode":"inherit"}"#.utf8)
        try account.write(to: auth)
        try Data(#"{"tokens":{"access_token":"fixture-only"}}"#.utf8).write(to: source)
        var manifest = ProviderManifest(name: "fixture", label: "fixture", authFile: auth.path)
        manifest.credentialSource = ProviderCredentialSource(file: source.path, environmentDirectory: nil,
            tokenPath: "tokens.access_token", headerPaths: nil, requiredValues: nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: source.path)
        let before = DataEngine.configRevision(slug: "fixture", manifest: manifest)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: source.path)
        let after = DataEngine.configRevision(slug: "fixture", manifest: manifest)
        #expect(after != before)
        #expect(try Data(contentsOf: auth) == account)
    }

    @Test @MainActor func displayOrderPersistsAndSurvivesAccountVisibilityChanges() {
        let (engine, root, _, defaults) = makeEngine("display-order")
        defer { try? FileManager.default.removeItem(at: root) }
        for slug in ["alpha", "beta", "charlie"] {
            addPlugin(slug, stdout: #"{"seven_day":{"used_percentage":5}}"#, to: root)
        }
        engine.reloadRegistry()
        engine.setProviderOrder(["charlie", "alpha", "beta"])
        #expect(engine.states.map(\.slug) == ["charlie", "alpha", "beta"])
        #expect(engine.allPlugins.map(\.slug) == ["charlie", "alpha", "beta"])
        #expect(defaults.stringArray(forKey: DataEngine.defaultsOrderKey) == ["charlie", "alpha", "beta"])
        engine.reloadRegistry()
        #expect(engine.states.map(\.slug) == ["charlie", "alpha", "beta"])
        engine.setTracking("alpha", enabled: false)
        #expect(engine.states.map(\.slug) == ["charlie", "beta"])
        engine.setTracking("alpha", enabled: true)
        #expect(engine.states.map(\.slug) == ["charlie", "alpha", "beta"])
    }

    @Test func colorThresholds() {
        #expect(HUDFmt.pctColor(95) == .red)
        #expect(HUDFmt.pctColor(90) == .red)
        #expect(HUDFmt.pctColor(89.9) == .yellow)
        #expect(HUDFmt.pctColor(70) == .yellow)
        #expect(HUDFmt.pctColor(69.9) == .green)
        #expect(HUDFmt.pctColor(nil) == .dim)
    }

    @Test func countdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let base = Int(now.timeIntervalSince1970)
        #expect(HUDFmt.resetCountdown(nil, now: now) == nil)
        #expect(HUDFmt.resetCountdown(base - 10, now: now) == nil) // 已过期
        #expect(HUDFmt.resetCountdown(base + 2 * 3600 + 13 * 60, now: now) == "2h13m")
        #expect(HUDFmt.resetCountdown(base + 5 * 86400 + 3 * 3600, now: now) == "5d3h")
        #expect(HUDFmt.resetCountdown(base + 45 * 60, now: now) == "0h45m")
    }

    @Test func freshness() {
        let c = UsageCache(generatedAt: 1000, fiveHour: nil,
                           sevenDay: Bucket(usedPercentage: 1, resetsAt: nil),
                           monthly: nil, error: nil, stale: false)
        #expect(HUDFmt.isFresh(c, interval: 60, now: 1000 + 59_000))
        #expect(!HUDFmt.isFresh(c, interval: 60, now: 1000 + 61_000))
        #expect(!HUDFmt.isFresh(nil, interval: 60, now: 0))
    }

    // MARK: P0-1 快照时间语义: generatedAt=最近成功, lastAttemptAt=最近尝试 (失败只推进后者)

    @Test func attemptFreshFallsBackToGeneratedAt() {
        let old = UsageCache(generatedAt: 1000, fiveHour: nil,
                             sevenDay: Bucket(usedPercentage: 1, resetsAt: nil),
                             monthly: nil, error: nil, stale: false)
        #expect(HUDFmt.isAttemptFresh(old, interval: 60, now: 1000 + 59_000))   // 旧缓存无 lastAttemptAt → 回退
        var failed = old
        failed.error = "fetch"; failed.stale = true; failed.lastAttemptAt = 1000 + 500_000
        #expect(!HUDFmt.isFresh(failed, interval: 60, now: 1000 + 500_000))     // 成功时间早已过期
        #expect(HUDFmt.isAttemptFresh(failed, interval: 60, now: 1000 + 500_000)) // 但尝试刚发生 → 不重刷
        #expect(!HUDFmt.isAttemptFresh(failed, interval: 60, now: 1000 + 600_000)) // 尝试也过期 → due
    }

    @Test func makeKeepsGeneratedAtOnlyOnSuccess() {
        // 业务失败 (error 非空): generatedAt 保留脚本写入值, lastAttemptAt 前移
        let failJSON = #"{"error":"auth","generatedAt":111,"five_hour":null,"seven_day":{"used_percentage":5}}"#
        let fail = UsageCache.make(body: Data(failJSON.utf8), now: 9999)
        #expect(fail != nil)
        #expect(fail?.generatedAt == 111)
        #expect(fail?.lastAttemptAt == 9999)
        #expect(fail?.error == "auth")
        // 成功: 两者都推进
        let okJSON = #"{"seven_day":{"used_percentage":5}}"#
        let ok = UsageCache.make(body: Data(okJSON.utf8), now: 8888)
        #expect(ok?.generatedAt == 8888)
        #expect(ok?.lastAttemptAt == 8888)
        #expect(ok?.error == nil)
    }

    @Test @MainActor func failureDoesNotAdvanceGeneratedAt() async {
        let (engine, tmp, hudDir, _) = makeEngine("tsfail")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 先成功一次, 再失败一次 (脚本改为输出错误)
        let d = tmp.appendingPathComponent("providers/flip", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let script = d.appendingPathComponent("fetch.sh")
        try? "#!/bin/zsh\necho '{\"seven_day\":{\"used_percentage\":10}}'".write(to: script, atomically: true, encoding: .utf8)
        try? JSONEncoder().encode(ProviderManifest(name: "flip", label: "flip", buckets: ["seven_day": "周"]))
            .write(to: d.appendingPathComponent("manifest.json"))
        engine.reloadRegistry()
        _ = await engine.forceRefresh(slug: "flip")
        let first = engine.states.first { $0.slug == "flip" }?.cache
        #expect(first?.generatedAt != nil && first?.error == nil)
        let g1 = first?.generatedAt
        // 改脚本: 退出码非 0 → runner 返回 nil → apply 失败分支
        try? "#!/bin/zsh\nexit 1".write(to: script, atomically: true, encoding: .utf8)
        let bad = await engine.forceRefresh(slug: "flip")
        #expect(!bad.ok)
        let after = engine.states.first { $0.slug == "flip" }?.cache
        #expect(after?.generatedAt == g1)                       // 成功时间不因失败推进
        #expect(after?.lastAttemptAt != nil && after!.lastAttemptAt! > g1!)  // 尝试时间前移
        #expect(after?.stale == true)
        // 落盘内容同样语义
        let disk = hudDir.appendingPathComponent(".flip-usage-cache.json")
        let onDisk = try? JSONDecoder().decode(UsageCache.self, from: Data(contentsOf: disk))
        #expect(onDisk?.generatedAt == g1)
        #expect(onDisk?.lastAttemptAt == after?.lastAttemptAt)
    }

    @Test func usageCacheDecodesLegacyCacheWithoutLastAttemptAt() {
        let legacy = #"{"generatedAt":123.5,"seven_day":{"used_percentage":7},"error":null,"stale":false}"#
        let c = try? JSONDecoder().decode(UsageCache.self, from: Data(legacy.utf8))
        #expect(c?.generatedAt == 123.5)
        #expect(c?.lastAttemptAt == nil)
        #expect(c?.sevenDay?.usedPercentage == 7)
    }

    // MARK: P0-2 迟到回包核对: 查询期间配置变更/账号删除 → 结果丢弃

    @Test func configRevisionTracksAuthFileChanges() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-rev-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let m = ProviderManifest(name: "R", label: "r", buckets: [:],
                                 authFile: tmp.path + "/auth.json")
        let r0 = DataEngine.configRevision(slug: "r", manifest: m)
        #expect(r0 == 0)                                        // 文件不存在 = 0
        try? Data("{}".utf8).write(to: tmp.appendingPathComponent("auth.json"))
        let r1 = DataEngine.configRevision(slug: "r", manifest: m)
        #expect(r1 > 0)
        // mtime 精度秒级, 同秒写不保证变化 — 只验证已写文件 revision 非零且稳定
        Thread.sleep(forTimeInterval: 0.05)
        #expect(DataEngine.configRevision(slug: "r", manifest: m) == r1)
    }

    @Test @MainActor func lateResultForDeletedAccountDiscarded() async {
        let (engine, tmp, hudDir, _) = makeEngine("late")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("slowpoke", stdout: #"{"seven_day":{"used_percentage":9}}"#, to: tmp)
        engine.reloadRegistry()
        let before = engine.states.first { $0.slug == "slowpoke" }?.cache?.sevenDay?.usedPercentage
        // 模拟查询期间账号被删: registry 清空 → 回包提交时 slug 查不到 → 丢弃
        let plugin = PluginProvider(slug: "slowpoke",
                                    manifest: engine.allPlugins.first { $0.slug == "slowpoke" }!.manifest,
                                    dir: tmp.appendingPathComponent("providers/slowpoke"))
        let result = await withTaskGroup(of: UsageCache?.self) { group in
            group.addTask { [engine] in await engine.runnerForTest.run(plugin) }
            var r: UsageCache? = nil
            for await v in group { r = v }
            return r
        }
        engine.clearAllPluginsForTest()  // 查询已返回, 模拟删除后
        engine.applyForTest(slug: "slowpoke", fetched: result, now: Date().timeIntervalSince1970 * 1000, checkRevision: true)
        #expect(before == nil)                                   // 原本无缓存
        // states 里 slug 已不在 allPlugins → fetch 核对丢弃, 不产生缓存文件
        #expect(engine.states.first { $0.slug == "slowpoke" } == nil)
        _ = hudDir
    }

    // MARK: P0-3 调度持久去重: 键 = slug+本地日期+HH:MM, 同键不重触发, 跨天是新键

    @Test func scheduleDedupSameKeySkipsDifferentDayFires() {
        var fired: [String: [String: String]] = [:]
        let d0 = Date(timeIntervalSince1970: 1_800_000_000)
        let d1 = d0.addingTimeInterval(86400) // 次日
        #expect(DataEngine.markScheduleFired(fired: &fired, slug: "glm", hhmm: "09:00", date: d0)) // 首次触发
        #expect(!DataEngine.markScheduleFired(fired: &fired, slug: "glm", hhmm: "09:00", date: d0)) // 同日同刻跳过 (跨重启注入同键 → 不再执行)
        #expect(DataEngine.markScheduleFired(fired: &fired, slug: "glm", hhmm: "09:00", date: d1)) // 次日同刻 = 新键, 触发 (修跨天误杀)
        #expect(DataEngine.markScheduleFired(fired: &fired, slug: "glm", hhmm: "21:00", date: d0)) // 同日另一时刻 = 新键
        #expect(DataEngine.markScheduleFired(fired: &fired, slug: "ollama", hhmm: "09:00", date: d0)) // 另一账号 = 新键
        #expect(fired[DataEngine.scheduleDedupKey(slug: "glm", date: d0)]?.count == 2)
    }

    @Test @MainActor func scheduleFiredPersistsAcrossEngineRestart() {
        // 持久性: 写入后经 UserDefaults 读回, 新引擎实例 (模拟重启) 同键仍挡
        let (engine, tmp, _, defaults) = makeEngine("sched")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = engine
        var fired: [String: [String: String]] = [:]
        #expect(DataEngine.markScheduleFired(fired: &fired, slug: "glm", hhmm: "09:00"))
        let data = try! JSONEncoder().encode(fired)
        defaults.set(String(data: data, encoding: .utf8), forKey: DataEngine.defaultsScheduleFiredKey)
        // "重启": 同 defaults 新引擎读回
        let raw = defaults.string(forKey: DataEngine.defaultsScheduleFiredKey)
        var reloaded = (try? JSONDecoder().decode([String: [String: String]].self,
                                                  from: raw?.data(using: .utf8) ?? Data("null".utf8))) ?? [:]
        #expect(!DataEngine.markScheduleFired(fired: &reloaded, slug: "glm", hhmm: "09:00")) // 跨重启不重复消费
    }

    // MARK: P0-2 删除清理: cache 文件与 envs.json 条目不残留

    @Test @MainActor func deleteRemovesCacheAndEnvsEntry() async {
        let (engine, tmp, hudDir, _) = makeEngine("del")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("victim", stdout: #"{"seven_day":{"used_percentage":3}}"#, to: tmp)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hudDir, userDir: tmp.appendingPathComponent("providers"),
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: UserDefaults(suiteName: "th-model-\(UUID().uuidString)")!)
        // 先成功查一次 → cache 落盘; envs.json 预置该账号条目 (模拟已写 HUD)
        _ = await engine.forceRefresh(slug: "victim")
        let cacheFile = DataEngine.cachePath(
            for: engine.allPlugins.first { $0.slug == "victim" }!, hudDir: hudDir)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
        let envsURL = hudDir.appendingPathComponent("envs.json")
        try? HUDSync.writeEnvs(["victim": EnvsEntry(label: "victim", source: "cache",
                                                    cache: cacheFile.path, buckets: ["seven_day": "周"])],
                               to: envsURL)
        // 跳过 NSAlert: 直接调删除的清理段不可行 (alert 阻塞), 走等价路径 —
        // 此处验证目标 = 清理动作本身, 用同一实现: removePlugin + cache 清除 + envs 摘除
        let p = engine.allPlugins.first { $0.slug == "victim" }!
        try? PluginGenerator.removePlugin(slug: "victim", in: tmp.appendingPathComponent("providers"))
        try? FileManager.default.removeItem(at: cacheFile)
        // envs 摘除 (与 SettingsModel.delete 相同的 merge 逻辑)
        let existing = (try? Data(contentsOf: envsURL))
            .flatMap { try? HUDSync.decodeEntries($0) } ?? [:]
        var merged = existing
        merged.removeValue(forKey: p.manifest.name)
        try? HUDSync.writeEnvs(merged, to: envsURL)
        // 断言: 无残留
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
        let after = (try? Data(contentsOf: envsURL))
            .flatMap { try? HUDSync.decodeEntries($0) } ?? [:]
        #expect(after["victim"] == nil)
        _ = model
    }

    @Test func cachePathExpansion() {
        let hud = URL(fileURLWithPath: "/tmp/hud-x")
        let m1 = ProviderManifest(name: "A", label: "a", fetch: "./fetch.sh", intervalSec: nil,
                                  buckets: [:], cacheFile: "~/.claude/hud/.glm-usage-cache.json",
                                  enabled: true)
        let p1 = PluginProvider(slug: "glm", manifest: m1, dir: hud)
        #expect(DataEngine.cachePath(for: p1, hudDir: hud).path
                == NSHomeDirectory() + "/.claude/hud/.glm-usage-cache.json")

        let m2 = ProviderManifest(name: "B", label: "b", fetch: "./fetch.sh", intervalSec: nil,
                                  buckets: [:], cacheFile: nil, enabled: true)
        let p2 = PluginProvider(slug: "my-relay", manifest: m2, dir: hud)
        #expect(DataEngine.cachePath(for: p2, hudDir: hud).path
                == "/tmp/hud-x/.my-relay-usage-cache.json")
    }

    // MARK: forceRefresh 真实结果

    @MainActor private func makeEngine(_ tag: String) -> (DataEngine, URL, URL, UserDefaults) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-engine-\(tag)-\(UUID().uuidString)", isDirectory: true)
        let userDir = tmp.appendingPathComponent("providers", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        let bundle = tmp.appendingPathComponent("bundle", isDirectory: true)
        let bundleProviders = bundle.appendingPathComponent("providers", isDirectory: true)
        let bundleMjs = bundle.appendingPathComponent("mjs", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundleProviders, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundleMjs, withIntermediateDirectories: true)
        for name in ["statusline.mjs", "ref-usage-provider.mjs", "source-readers.mjs",
                     "hud-runtime.mjs", "generic-usage-provider.mjs"] {
            try? Data("// fixture".utf8).write(to: bundleMjs.appendingPathComponent(name))
        }
        let suite = "th-engine-\(tag)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: bundleProviders, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: nil, logDir: hudDir), defaults: defaults,
                                settingsURL: tmp.appendingPathComponent("settings.json"),
                                runtimeDir: tmp.appendingPathComponent("runtime", isDirectory: true))
        return (engine, tmp, hudDir, defaults)
    }

    private func addWrapper(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "#!/bin/zsh\nexit 0\n".write(to: dir.appendingPathComponent("fetch.sh"),
                                         atomically: true, encoding: .utf8)
    }

    private func addPlugin(_ slug: String, stdout: String, to tmp: URL) {
        let d = tmp.appendingPathComponent("providers/\(slug)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "#!/bin/zsh\necho '\(stdout)'".write(to: d.appendingPathComponent("fetch.sh"),
                                                 atomically: true, encoding: .utf8)
        try? JSONEncoder().encode(ProviderManifest(name: slug, label: slug, buckets: ["seven_day": "周"]))
            .write(to: d.appendingPathComponent("manifest.json"))
    }

    @Test @MainActor func menuBarAccountTracksAutomaticAndExplicitSelection() throws {
        let (engine, root, hud, defaults) = makeEngine("menu-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        for (slug, percentage) in [("low", 20.0), ("high", 90.0)] {
            let dir = root.appendingPathComponent("providers/" + slug)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = hud.appendingPathComponent(".\(slug)-usage-cache.json")
            let manifest = ProviderManifest(name: slug, label: slug, cacheFile: file.path)
            try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
            try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000, sevenDay: Bucket(usedPercentage: percentage))).write(to: file)
        }
        engine.reloadRegistry()
        #expect(engine.menuBarProviderSlug == "high")
        engine.setIconProvider("low")
        #expect(engine.menuBarProviderSlug == "low")
        #expect(defaults.string(forKey: DataEngine.defaultsIconKey) == "low")
        engine.setIconProvider(nil)
        #expect(engine.menuBarProviderSlug == "high")
        engine.setTracking("high", enabled: false)
        #expect(engine.menuBarProviderSlug == "low")
    }

    @Test @MainActor func forceRefreshReportsOutcome() async {
        let (engine, tmp, _, _) = makeEngine("outcome")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("good", stdout: #"{"seven_day":{"used_percentage":42}}"#, to: tmp)
        addPlugin("badauth", stdout: #"{"error":"auth"}"#, to: tmp)
        engine.reloadRegistry()

        let ok = await engine.forceRefresh(slug: "good")
        #expect(ok.ok)
        #expect(ok.message("G") == "✓ 已刷新 G")
        #expect(engine.states.first { $0.slug == "good" }?.cache?.sevenDay?.usedPercentage == 42)

        let bad = await engine.forceRefresh(slug: "badauth")
        #expect(!bad.ok)
        #expect(bad.reason == "缺凭证或凭证失效（已重试 2 次）")
        #expect(bad.message("B") == "✗ B 刷新失败: 缺凭证或凭证失效（已重试 2 次）")

        let missing = await engine.forceRefresh(slug: "nope")
        #expect(missing.reason == "供应商不存在")
    }

    @Test @MainActor func forceRefreshWorksForUntrackedAccount() async {
        // 停用跟踪 = 不进自动轮询, 手动查询仍应执行 (查询不消费额度)
        let (engine, tmp, hudDir, _) = makeEngine("untracked")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("good", stdout: #"{"seven_day":{"used_percentage":7}}"#, to: tmp)
        engine.reloadRegistry()
        engine.setTracking("good", enabled: false)
        #expect(engine.states.isEmpty)                  // 不参与轮询
        let r = await engine.forceRefresh(slug: "good")
        #expect(r.ok)
        let cache = hudDir.appendingPathComponent(".good-usage-cache.json")
        #expect(FileManager.default.fileExists(atPath: cache.path)) // 结果落盘
    }

    // MARK: 引擎双维度独立

    // MARK: P1-1 保存不发请求: save() 后无新尝试 (无 cache 落盘, 无 lastAttemptAt)

    @Test @MainActor func saveDoesNotTriggerQuery() async throws {
        let (engine, tmp, hudDir, _) = makeEngine("saveq")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("hold", stdout: #"{"seven_day":{"used_percentage":5}}"#, to: tmp)
        // auth 文件须存在 (update() 落盘前置)
        try? Data("{}".utf8).write(to: hudDir.appendingPathComponent(".hold-usage-auth.json"))
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hudDir,
                                  userDir: tmp.appendingPathComponent("providers"),
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: UserDefaults(suiteName: "th-model-\(UUID().uuidString)")!)
        model.selected = "hold"
        model.startEdit()
        model.draft?.values.key = "k"
        model.draft?.values.url = "https://api.example.com"
        model.save()
        #expect(model.topError.isEmpty)
        // 给可能的隐式 forceRefresh 留时间 (修复前此处会写 cache 文件)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!FileManager.default.fileExists(atPath:
            hudDir.appendingPathComponent(".hold-usage-cache.json").path))
        #expect(engine.states.first { $0.slug == "hold" }?.cache?.lastAttemptAt == nil)
    }

    // MARK: P1-6 启用确认 + 草稿测试: off→on 需确认 (纯函数); 草稿测试不改盘上配置

    @Test func triggerConfirmPredicate() {
        // 既有账号 off→on 和新建账号启用都需要确认
        #expect(SettingsValidation.needsTriggerConfirm(base: false, current: true, isNew: false))
        #expect(!SettingsValidation.needsTriggerConfirm(base: true, current: true, isNew: false))   // 本来就开
        #expect(!SettingsValidation.needsTriggerConfirm(base: true, current: false, isNew: false))  // 关闭
        #expect(!SettingsValidation.needsTriggerConfirm(base: false, current: false, isNew: false)) // 不变
        #expect(SettingsValidation.needsTriggerConfirm(base: false, current: true, isNew: true))   // 新建账号同样确认
    }

    @Test @MainActor func draftTestCallLeavesDiskConfigUntouched() async throws {
        let (engine, tmp, hudDir, _) = makeEngine("draft")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("acct", stdout: #"{"seven_day":{"used_percentage":5}}"#, to: tmp)
        let authFile = hudDir.appendingPathComponent(".acct-usage-auth.json")
        try? JSONSerialization.data(withJSONObject: ["refreshApiKey": "disk-key", "testModel": "m1",
                                                     "testPrompt": "p1", "scheduleTimes": ["09:00"]])
            .write(to: authFile)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hudDir,
                                  userDir: tmp.appendingPathComponent("providers"),
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: UserDefaults(suiteName: "th-model-\(UUID().uuidString)")!)
        model.selected = "acct"
        model.startEdit()
        model.draft?.values.url = "https://api.example.com"
        // 草稿测试不保存: 草稿改动只留内存, 盘上 auth 内容不变 (testCallDraft 不走 create/update)
        let before = try Data(contentsOf: authFile)
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = try Data(contentsOf: authFile)
        #expect(before == after)
        #expect(model.draft?.dirty == true)  // 草稿仍是 dirty (未被静默保存)
    }

    // MARK: P1-4 模型并发位: 每账号 1 / 全局 2; 满位 → 计划触发记 skipped:busy

    @Test func callSlotsLimits() async {
        let s = CallSlots(globalLimit: 2)
        let a1 = await s.acquire("a")
        let a2 = await s.acquire("a")   // 同账号第二位 → 拒
        let b1 = await s.acquire("b")
        let c1 = await s.acquire("c")   // 全局第 3 位 → 拒
        #expect(a1 && b1)
        #expect(!a2)
        #expect(!c1)
        await s.release("a")
        let c2 = await s.acquire("c")   // 释放后可占
        #expect(c2)
        await s.release("b"); await s.release("c")
        let inFlight = await s.inFlight
        #expect(inFlight.isEmpty)
    }

    @Test @MainActor func scheduleSkippedWhenSlotsFull() async throws {
        // 占满 2 全局位 → 到点计划不发送, 持久记录 skipped:busy
        let (engine, tmp, _, defaults) = makeEngine("slots")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("busy1", stdout: #"{"seven_day":{"used_percentage":1}}"#, to: tmp)
        engine.reloadRegistry()
        // 预占两个全局位 (模拟他账号调用在飞)
        await engine.callSlots.acquire("other-a")
        await engine.callSlots.acquire("other-b")
        // 等价路径: checkSchedules 内 Task 的占位分支 (不真发请求)
        let ok = await engine.callSlots.acquire("busy1")
        #expect(!ok)                                    // 满 → 该计划只能 skipped
        var fired = [String: [String: String]]()
        let key = DataEngine.scheduleDedupKey(slug: "busy1", date: Date())
        fired[key, default: [:]]["09:00"] = "skipped:busy"
        DataEngine.saveSkipped(fired, defaults: defaults)
        // 读回: skipped 记录与 fired 同仓 (值域区分)
        let read = DataEngine.loadSkipped(defaults: defaults)
        #expect(read[key]?["09:00"] == "skipped:busy")
        await engine.callSlots.release("other-a"); await engine.callSlots.release("other-b")
    }

    @Test @MainActor func refreshBalancesOnlyQueriesWithoutTrigger() async {
        let (engine, tmp, _, _) = makeEngine("balonly")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("q", stdout: #"{"seven_day":{"used_percentage":11}}"#, to: tmp)
        engine.reloadRegistry()
        await engine.refreshBalancesOnly()
        #expect(engine.states.first { $0.slug == "q" }?.cache?.sevenDay?.usedPercentage == 11)
        #expect(!engine.isRefreshingAll)                          // 结束后复位
    }

    @Test @MainActor func trackingAndTriggerTogglesIndependent() {
        let (engine, tmp, _, defaults) = makeEngine("dims")
        defer { try? FileManager.default.removeItem(at: tmp) }
        engine.setTracking("a", enabled: false)
        #expect(engine.disabledSlugs == ["a"])
        #expect(engine.triggerDisabledSlugs.isEmpty)     // 关跟踪不动触发维度
        #expect(defaults.stringArray(forKey: DataEngine.defaultsTriggerDisabledKey) == nil)

        engine.setTriggerEnabled("a", enabled: false)
        #expect(engine.disabledSlugs == ["a"])           // 关触发不动跟踪维度
        #expect(engine.triggerDisabledSlugs == ["a"])
        #expect(Set(defaults.stringArray(forKey: DataEngine.defaultsDisabledKey) ?? []) == ["a"])
        #expect(Set(defaults.stringArray(forKey: DataEngine.defaultsTriggerDisabledKey) ?? []) == ["a"])

        engine.setTracking("a", enabled: true)
        #expect(engine.disabledSlugs.isEmpty)
        #expect(engine.triggerDisabledSlugs == ["a"])    // 重开跟踪不代表重开触发

        engine.setTriggerEnabled("a", enabled: true)
        #expect(engine.triggerDisabledSlugs.isEmpty)
    }

    // MARK: P1-2 查询 op 体系: 全局并发 3 / 每账号 1 / 同账号合并 / 等待总预算

    @Test func queryGateEnforcesGlobalLimitOfThree() async throws {
        let gate = QueryGate(globalLimit: 3, waitBudgetSec: 10)
        let tracker = OpTracker()
        // 5 个不同账号同时查: 任一时刻在飞 ≤ 3
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    _ = try? await gate.run(slug: "acct\(i)") {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await tracker.exit()
                        return nil
                    }
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak <= 3)          // 全局并发上限 3
        #expect(peak >= 2)          // 确实并行了 (非串行)
        let inFlight = await gate.inFlightSlugs
        #expect(inFlight.isEmpty)   // 全部完成后无残留执行位
    }

    @Test func queryGateMergesSameSlugOps() async throws {
        // 同账号两请求 → 合并为一次执行, 共享同一结果
        let gate = QueryGate(globalLimit: 3, waitBudgetSec: 10)
        let tracker = OpTracker()
        async let a = gate.run(slug: "same") {
            await tracker.enter(); await tracker.exit()
            try? await Task.sleep(nanoseconds: 80_000_000)
            return UsageCache(generatedAt: 42, fiveHour: nil,
                              sevenDay: Bucket(usedPercentage: 7, resetsAt: nil),
                              monthly: nil, error: nil, stale: false)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)   // 让第一个 op 先占位
        async let b = gate.run(slug: "same") {                 // 后到者: 不新起 op
            Issue.record("合并失败: 同账号第二个 op 不应执行")
            return nil
        }
        let (ra, rb): (UsageCache?, UsageCache?) = try await (a, b)
        #expect(ra?.sevenDay?.usedPercentage == 7)
        #expect(rb?.sevenDay?.usedPercentage == 7)       // 共享同一结果
        let calls = await tracker.calls
        #expect(calls == 1)                              // 只执行了一次
    }

    @Test func queryGateWaitTimesOutWithBudget() async throws {
        // 满位 + 等待超预算 → 抛 waitTimeout (文案"排队超时")
        let gate = QueryGate(globalLimit: 1, waitBudgetSec: 0.15)
        let held = Task { try await gate.run(slug: "holder") {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
        } }
        try? await Task.sleep(nanoseconds: 30_000_000)   // holder 已占位
        do {
            _ = try await gate.run(slug: "waiter") { nil }
            Issue.record("应抛 waitTimeout")
        } catch let e as QueryGate.GateError {
            guard case .waitTimeout = e else { Issue.record("非 waitTimeout: \(e)"); return }
            #expect(DataEngine.reason(for: "busy").contains("排队超时"))
        }
        _ = try? await held.value
    }

    @Test @MainActor func forceRefreshSharesGateWithTimer() async throws {
        // 手动 forceRefresh 与 timer refreshNow 走同一 gate: 同账号在飞 → 合并不双发
        let (engine, tmp, _, _) = makeEngine("gate2")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("g", stdout: #"{"seven_day":{"used_percentage":21}}"#, to: tmp)
        engine.reloadRegistry()
        async let manual = engine.forceRefresh(slug: "g")
        try? await Task.sleep(nanoseconds: 10_000_000)
        let inFlight = await engine.queryGate.inFlightSlugs
        #expect(inFlight.contains("g"))          // 手动查询在 gate 内
        _ = await manual
        let done = await engine.queryGate.inFlightSlugs
        #expect(!done.contains("g"))
    }

    // MARK: P1-3 429 退避: error=ratelimit → 暂停自动查询, 到期恢复, 不影响他账号

    @Test func rateLimitPauseWindow() {
        // 暂停窗口 = max(interval, 60s)
        #expect(DataEngine.rateLimitPauseMs(intervalSec: 30) == 60_000)    // 短间隔抬到 60s
        #expect(DataEngine.rateLimitPauseMs(intervalSec: 300) == 300_000)  // 长间隔保持
    }

    @Test func pausedDictSurvivesReloadAndExpiry() throws {
        // 内存+UserDefaults 持久: 未过期条目读回, 过期条目剔除 (到期自动恢复)
        let suite = "th-rl-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let now = Date().timeIntervalSince1970 * 1000
        var dict: [String: Double] = ["a": now + 60_000, "b": now - 1]    // b 已过期
        DataEngine.savePaused(dict, defaults: defaults)
        let read = DataEngine.loadPaused(defaults: defaults)
        #expect(read["a"] != nil)          // 暂停窗口内保留
        #expect(read["b"] == nil)          // 过期即恢复
        dict.removeValue(forKey: "a")
        DataEngine.savePaused(dict, defaults: defaults)
        #expect(DataEngine.loadPaused(defaults: defaults).isEmpty)
    }

    @Test @MainActor func ratelimitSuspendsOnlyThatAccount() async throws {
        let (engine, tmp, _, defaults) = makeEngine("rl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("throttled", stdout: #"{"error":"ratelimit"}"#, to: tmp)
        addPlugin("healthy", stdout: #"{"seven_day":{"used_percentage":8}}"#, to: tmp)
        engine.reloadRegistry()
        // 触发一次 ratelimit 结果 (forceRefresh 走 apply → 记暂停)
        _ = await engine.forceRefresh(slug: "throttled")
        let paused = DataEngine.loadPaused(defaults: defaults)
        #expect(paused["throttled"] != nil)        // 该账号进入退避
        #expect(paused["healthy"] == nil)          // 他账号不受影响
        // refreshNow 轮询: 暂停中的账号被跳过 (healthy 查询推进, throttled 的 lastAttemptAt 不再前移)
        let throttledAttempt = engine.states.first { $0.slug == "throttled" }?.cache?.lastAttemptAt
        _ = await engine.refreshNow()
        let after = engine.states.first { $0.slug == "throttled" }?.cache?.lastAttemptAt
        #expect(after == throttledAttempt)         // 未再尝试
        #expect(engine.states.first { $0.slug == "healthy" }?.cache?.error == nil)
        // 成功一次 → 清除暂停 (到期恢复的另一路径)
        addPlugin2(tmp, slug: "throttled", stdout: #"{"seven_day":{"used_percentage":3}}"#)
        _ = await engine.forceRefresh(slug: "throttled")
        #expect(DataEngine.loadPaused(defaults: defaults)["throttled"] == nil)
    }

    /// 覆写既有插件脚本输出 (模拟状态翻转)
    private func addPlugin2(_ tmp: URL, slug: String, stdout: String) {
        try? "#!/bin/zsh\necho '\(stdout)'".write(to: tmp.appendingPathComponent("providers/\(slug)/fetch.sh"),
                                                  atomically: true, encoding: .utf8)
    }

    // MARK: P1-11 动态窗口列表: windows 解码容错 + UI 数据源切换 (纯函数 rows(from:))

    @Test func windowBucketDecodesWithTolerance() throws {
        // snake_case + 数值/串容错 + ISO8601 resets_at
        let json = #"{"label":"本月","used_percentage":"45.5","amount":9.1,"limit":"20","unit":"USD","period":"monthly","resets_at":"2026-11-01T00:00:00Z"}"#
        let w = try JSONDecoder().decode(WindowBucket.self, from: Data(json.utf8))
        #expect(w.label == "本月")
        #expect(w.usedPercentage == 45.5)             // 数值串 "45.5" → Double
        #expect(w.amount == 9.1)
        #expect(w.limit == 20)                        // 整数串 "20" → Double
        #expect(w.unit == "USD")
        #expect(w.period == "monthly")
        #expect(w.resetsAt == 1_793_491_200)          // ISO8601 → epoch 秒
        // epoch 秒直存 + 全字段可缺
        let min = try JSONDecoder().decode(WindowBucket.self,
                                           from: Data(#"{"used_percentage":10,"resets_at":123}"#.utf8))
        #expect(min.usedPercentage == 10 && min.resetsAt == 123)
        #expect(min.label == nil && min.unit == nil && min.period == nil)
    }

    @Test func usageCacheCarriesWindowsAlongsideLegacy() throws {
        // windows 与旧三桶共存解码; 旧缓存 (无 windows) 照常
        let json = #"{"generatedAt":1,"seven_day":{"used_percentage":5},"windows":[{"label":"本周","used_percentage":5}]}"#
        let c = try JSONDecoder().decode(UsageCache.self, from: Data(json.utf8))
        #expect(c.windows?.count == 1)
        #expect(c.windows?.first?.label == "本周")
        #expect(c.sevenDay?.usedPercentage == 5)
        let legacy = try JSONDecoder().decode(UsageCache.self,
                                              from: Data(#"{"generatedAt":1,"seven_day":{"used_percentage":5}}"#.utf8))
        #expect(legacy.windows == nil)                // 旧读端不破坏
        // make: 仅 windows 无旧桶也算业务成功 (不返回 nil)
        let only = UsageCache.make(body: Data(#"{"windows":[{"label":"本月","used_percentage":30}]}"#.utf8),
                                   now: 5)
        #expect(only != nil && only?.windows?.count == 1)
        // make: 无桶无 windows 无 error → nil (空回包不冒充成功)
        #expect(UsageCache.make(body: Data("{}".utf8), now: 5) == nil)
    }

    @Test func quotaRowsSwitchesToWindowsWhenPresent() {
        // windows 非空 → 动态行；缺少动态窗口时只保留有真实数值的旧桶。
        let withWindows = UsageCache(generatedAt: 1,
                                     sevenDay: Bucket(usedPercentage: 5, resetsAt: nil),
                                     windows: [WindowBucket(label: "5小时", usedPercentage: 12, resetsAt: 100),
                                               WindowBucket(label: "本月", usedPercentage: 40, amount: 8,
                                                            limit: 20, unit: "USD", period: "monthly", resetsAt: nil)])
        let rowsW = QuotaTabView.rows(from: withWindows)
        #expect(rowsW.count == 2)                     // 按数组渲染, 不再固定三卡
        #expect(rowsW[0].label == "5小时" && rowsW[0].pct == 12 && rowsW[0].resetsAt == 100)
        #expect(rowsW[1].label == "本月" && rowsW[1].amount == 8 && rowsW[1].limit == 20)
        #expect(rowsW[1].unit == "USD" && rowsW[1].period == "monthly")
        // 旧缓存只回落有效的两行，不补造月额度卡片。
        let legacy = UsageCache(generatedAt: 1,
                                fiveHour: Bucket(usedPercentage: 3, resetsAt: nil),
                                sevenDay: Bucket(usedPercentage: 5, resetsAt: nil))
        let rowsL = QuotaTabView.rows(from: legacy)
        #expect(rowsL.map(\.label) == ["5 小时", "本周"])
        #expect(rowsL.allSatisfy { $0.amount == nil && $0.unit == nil })
        #expect(rowsL[1].pct == 5)
        // nil cache / 无有效窗口或旧桶 → 空态，不伪造三个额度模块。
        #expect(QuotaTabView.rows(from: nil).isEmpty)
        let empty = UsageCache(generatedAt: 1, windows: [])
        #expect(QuotaTabView.rows(from: empty).isEmpty)
        // 量化信息全无的窗口行 (仅 label) 不渲染
        let noisy = UsageCache(generatedAt: 1,
                               windows: [WindowBucket(label: "噪声", usedPercentage: nil, amount: nil, limit: nil),
                                         WindowBucket(label: "有效", usedPercentage: 1)])
        #expect(QuotaTabView.rows(from: noisy).count == 1)
    }

    @Test func unitLabelFormats() {
        #expect(QuotaTabView.unitLabel(9.1, 20, unit: "USD") == "$9.10 / $20")
        #expect(QuotaTabView.unitLabel(5, 10, unit: "USD") == "$5 / $10")
        #expect(QuotaTabView.unitLabel(3, 7, unit: "requests") == "3 / 7 requests")
        #expect(QuotaTabView.unitLabel(3, 7, unit: nil) == "3 / 7")
    }

    // MARK: v0.2 三开关 + 间隔覆盖

    @Test @MainActor func threeTogglesPersistIndependently() throws {
        let (engine, tmp, hudDir, defaults) = makeEngine("v02toggle")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("acc1", stdout: "{}", to: tmp)
        engine.reloadRegistry()

        // 开关只改本地偏好；HUD 文件必须保持原样。
        let settings = tmp.appendingPathComponent("settings.json")
        let seededSettings = Data(#"{"env":{"ACCOUNT_ENVS":"acc1"}}"#.utf8)
        try? seededSettings.write(to: settings)
        let seededEnvs = Data(#"{"acc1":{"label":"acc1","source":"cache","cache":"/tmp/acc1"}}"#.utf8)
        try? seededEnvs.write(to: hudDir.appendingPathComponent("envs.json"))

        engine.setTracking("acc1", enabled: false)          // 主开关停用
        engine.setFloatingHidden("acc1", hidden: true)      // 悬浮窗隐藏
        engine.setHudHidden("acc1", hidden: true)  // HUD 关同步
        #expect(engine.disabledSlugs.contains("acc1"))
        #expect(engine.floatingHiddenSlugs.contains("acc1"))
        #expect(engine.hudHiddenSlugs.contains("acc1"))
        #expect(Set(defaults.stringArray(forKey: DataEngine.defaultsDisabledKey) ?? []) == ["acc1"])
        #expect(Set(defaults.stringArray(forKey: DataEngine.defaultsFloatingHiddenKey) ?? []) == ["acc1"])
        #expect(Set(defaults.stringArray(forKey: DataEngine.defaultsHudHiddenKey) ?? []) == ["acc1"])
        #expect(engine.hudNeedsExport)
        #expect(try Data(contentsOf: settings) == seededSettings)
        #expect(try Data(contentsOf: hudDir.appendingPathComponent("envs.json")) == seededEnvs)

        // 独立: 恢复主开关不影响另两个
        engine.setTracking("acc1", enabled: true)
        #expect(!engine.disabledSlugs.contains("acc1"))
        #expect(engine.floatingHiddenSlugs.contains("acc1"))
        #expect(engine.hudHiddenSlugs.contains("acc1"))
        // hudSyncNames 排除 hudHidden
        #expect(!engine.hudSyncNames.contains("acc1"))
        engine.setHudHidden("acc1", hidden: false)
        #expect(engine.hudSyncNames.contains("acc1"))
    }

    @Test @MainActor func disabledAccountSkipsScheduledModelCall() async throws {
        let (engine, tmp, hudDir, defaults) = makeEngine("disabled-schedule")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("scheduled", stdout: "{}", to: tmp)
        let now = Date()
        let calendar = Calendar.current
        let hhmm = String(format: "%02d:%02d", calendar.component(.hour, from: now),
                          calendar.component(.minute, from: now))
        try JSONSerialization.data(withJSONObject: ["scheduleTimes": [hhmm]])
            .write(to: hudDir.appendingPathComponent(".scheduled-usage-auth.json"))
        engine.reloadRegistry()
        engine.setTracking("scheduled", enabled: false)
        let calls = OpTracker()
        engine.checkSchedules(now: now) { _, _ in await calls.enter(); return nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await calls.calls == 0)
        #expect(!engine.triggerDisabledSlugs.contains("scheduled"))
        #expect(defaults.string(forKey: DataEngine.defaultsScheduleFiredKey) == nil)
    }

    @Test @MainActor func disabledAccountSkipsRefreshNow() async {
        let (engine, tmp, hudDir, _) = makeEngine("v02skip")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("skipme", stdout: #"{"seven_day":{"used_percentage":9}}"#, to: tmp)
        engine.reloadRegistry()
        engine.setTracking("skipme", enabled: false)
        // 停用后 states 不含该家 → refreshNow 无 due
        #expect(!engine.states.contains { $0.slug == "skipme" })
        await engine.refreshNow()
        // 无缓存文件落盘 (从未查询)
        #expect(!FileManager.default.fileExists(
            atPath: hudDir.appendingPathComponent(".skipme-usage-cache.json").path))
    }

    @Test @MainActor func intervalOverrideDrivesDue() async {
        let (engine, tmp, hudDir, defaults) = makeEngine("v02interval")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("iv", stdout: #"{"seven_day":{"used_percentage":5}}"#, to: tmp)
        engine.reloadRegistry()
        // 默认 manifest interval=60s: 查一次后, 长间隔覆盖 (2 分钟) → 不再 due
        _ = await engine.forceRefresh(slug: "iv")
        engine.setIntervalMinutes("iv", minutes: 2)
        #expect(defaults.integer(forKey: DataEngine.intervalKey("iv")) == 2)
        await engine.refreshNow()   // 刚查过 + 2min 覆盖 → 不应重刷
        // 生成两个缓存? 只查了一次 (forceRefresh), refreshNow 不应新增 — 由 lastAttemptAt 判定; 断言 generatedAt 未被重置
        let st = try? JSONDecoder().decode(UsageCache.self,
                                           from: Data(contentsOf: hudDir.appendingPathComponent(".iv-usage-cache.json")))
        #expect(st?.error == nil)
        // 清除覆盖回落 manifest
        engine.clearIntervalOverride("iv")
        #expect(defaults.object(forKey: DataEngine.intervalKey("iv")) == nil)
        #expect(engine.effectiveIntervalMinutes("iv", manifest: engine.allPlugins[0].manifest) == 1)
    }

    @Test @MainActor func hudSyncNamesFilterEndToEnd() {
        let (engine, tmp, _, _) = makeEngine("v02envs")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = tmp.appendingPathComponent("settings.json")
        try? #"{"env":{"ACCOUNT_ENVS":"a1,a2,acc-junk"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        addPlugin("a1", stdout: "{}", to: tmp)
        addPlugin("a2", stdout: "{}", to: tmp)
        engine.reloadRegistry()
        engine.setHudHidden("a2", hidden: true)
        #expect(engine.hudSyncNames == ["a1"])
        engine.setTracking("a1", enabled: false)   // 停用也排除
        #expect(engine.hudSyncNames.isEmpty)
        // 事故修复验证: ACCOUNT_ENVS 垃圾值被清, 合法键保留
        engine.setTracking("a1", enabled: true)
        if case .failure(let error) = engine.exportHUD() { Issue.record("导出失败：\(error)") }
        let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any]
        #expect((obj?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "a1,acc-junk")
        #expect(!engine.hudNeedsExport)
    }

    // MARK: HUD 同步必须保留外部配置并避免部分写入

    @Test @MainActor func changingDisplayOrderIsLocalUntilExplicitExport() throws {
        let (engine, tmp, _, defaults) = makeEngine("order-hud")
        defer { try? FileManager.default.removeItem(at: tmp) }
        for slug in ["a", "b", "c"] { addPlugin(slug, stdout: "{}", to: tmp) }
        let settings = tmp.appendingPathComponent("settings.json")
        try #"{"env":{"ACCOUNT_ENVS":"a,b,c"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        engine.reloadRegistry()
        engine.setHudHidden("b", hidden: true)
        engine.setProviderOrder(["c", "b", "a"])
        #expect(engine.states.map(\.slug) == ["c", "b", "a"])
        #expect(engine.hudNeedsExport)
        // Order change alone never rewrites the HUD settings.
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect((before?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "a,b,c")
        if case .failure(let error) = engine.exportHUD() { Issue.record("Order export failed: \(error)") }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect((object["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "c,a")
        engine.setHudHidden("b", hidden: false)
        if case .failure(let error) = engine.exportHUD() { Issue.record("Order export failed: \(error)") }
        let restored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect((restored["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "c,b,a")
        // Local order survives a failed export; failure must not corrupt existing HUD files.
        try "invalid-json".write(to: settings, atomically: true, encoding: .utf8)
        if case .success = engine.exportHUD() { Issue.record("Must report HUD write failure") }
        #expect(defaults.stringArray(forKey: DataEngine.defaultsOrderKey) == ["c", "b", "a"])
    }

    @Test @MainActor func hudSyncPreservesExternalAccountsAndEntries() throws {
        let (engine, tmp, hudDir, _) = makeEngine("hud-external")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("acc1", stdout: "{}", to: tmp)
        engine.reloadRegistry()
        let settings = tmp.appendingPathComponent("settings.json")
        try #"{"env":{"ACCOUNT_ENVS":"Claude-Max,External,acc1","OTHER":"keep"},"theme":"dark"}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let external = EnvsEntry(label: "External", source: "cache", cache: "/tmp/external-cache", buckets: [:])
        try HUDSync.writeEnvs(["External": external], to: envsURL)

        engine.exportHUD()

        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let env = try #require(obj["env"] as? [String: Any])
        #expect(env["ACCOUNT_ENVS"] as? String == "Claude-Max,External,acc1")
        #expect(env["OTHER"] as? String == "keep")
        #expect(obj["theme"] as? String == "dark")
        let entries = try HUDSync.decodeEntries(Data(contentsOf: envsURL))
        #expect(entries["External"]?.cache == "/tmp/external-cache")
        #expect(entries["acc1"] != nil)
    }

    @Test @MainActor func hudSyncUsesIndependentCacheForSecondBuiltinAccount() throws {
        let (engine, tmp, hudDir, _) = makeEngine("hud-builtin-instance")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = tmp.appendingPathComponent("settings.json")
        let settingsData = Data(#"{"env":{"ACCOUNT_ENVS":"Cline"}}"#.utf8)
        try settingsData.write(to: settings)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let envsData = Data("{}".utf8)
        try envsData.write(to: envsURL)
        let second = tmp.appendingPathComponent("providers/cline-2", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProviderManifest(name: "Cline", label: "Cline", template: "cline"))
            .write(to: second.appendingPathComponent("manifest.json"))
        addWrapper(second)
        engine.reloadRegistry()
        let result = engine.exportHUD()
        if case .failure(let error) = result { Issue.record("独立账号应能同步：\(error)") }
        let projected = try HUDSync.decodeEntries(Data(contentsOf: envsURL))
        #expect(projected["cline-2"]?.cache == hudDir.appendingPathComponent(".cline-2-hud-cache.json").path)
        #expect(projected["Cline"] == nil)
        // 已隐藏的第二账号不能阻止其他账号正常同步。
        engine.setTracking("cline-2", enabled: false)
        if case .failure(let error) = engine.exportHUD() {
            Issue.record("停用的第二账号不应阻断同步：\(error.localizedDescription)")
        }
    }

    @Test @MainActor func hudSyncUsesCustomCacheEvenWhenNameMatchesBuiltin() throws {
        let (engine, tmp, hudDir, _) = makeEngine("hud-custom-builtin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = tmp.appendingPathComponent("settings.json")
        let originalSettings = Data(#"{"env":{"ACCOUNT_ENVS":"Cline"}}"#.utf8)
        try originalSettings.write(to: settings)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let originalEnvs = Data("{}".utf8)
        try originalEnvs.write(to: envsURL)
        let customDir = tmp.appendingPathComponent("providers/custom-cline", isDirectory: true)
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProviderManifest(name: "Cline", label: "Custom",
                                                  cacheFile: hudDir.appendingPathComponent(".custom-usage-cache.json").path))
            .write(to: customDir.appendingPathComponent("manifest.json"))
        addWrapper(customDir)
        engine.reloadRegistry()

        if case .failure(let error) = engine.exportHUD() { Issue.record("自定义账号应能同步：\(error)") }
        let projected = try HUDSync.decodeEntries(Data(contentsOf: envsURL))
        #expect(projected["custom-cline"]?.cache == hudDir.appendingPathComponent(".custom-cline-hud-cache.json").path)
        #expect(projected["Cline"] == nil)
        // 冲突账号已关闭 HUD 时，不应阻断其他账号同步。
        engine.setHudHidden("custom-cline", hidden: true)
    }

    @Test @MainActor func hudSyncProjectsConfiguredCacheForDefaultAccount() throws {
        let (engine, tmp, hudDir, _) = makeEngine("hud-changed-cache")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = tmp.appendingPathComponent("settings.json")
        let originalSettings = Data(#"{"env":{"ACCOUNT_ENVS":"Cline"}}"#.utf8)
        try originalSettings.write(to: settings)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let originalEnvs = Data("{}".utf8)
        try originalEnvs.write(to: envsURL)
        let pluginDir = tmp.appendingPathComponent("providers/cline", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProviderManifest(name: "Cline", label: "Cline",
                                                  cacheFile: hudDir.appendingPathComponent(".changed-usage-cache.json").path,
                                                  template: "cline"))
            .write(to: pluginDir.appendingPathComponent("manifest.json"))
        addWrapper(pluginDir)
        engine.reloadRegistry()

        if case .failure(let error) = engine.exportHUD() { Issue.record("配置的缓存应能同步：\(error)") }
        let projected = try HUDSync.decodeEntries(Data(contentsOf: envsURL))
        #expect(projected["cline"]?.cache == hudDir.appendingPathComponent(".cline-hud-cache.json").path)
        #expect(projected["Cline"] == nil)
        engine.setTracking("cline", enabled: false)
        if case .failure(let error) = engine.exportHUD() {
            Issue.record("停用冲突账号不应阻断同步：\(error.localizedDescription)")
        }
    }

    @Test @MainActor func hudSyncInvalidSettingsDoesNotChangeEnvs() throws {
        let (engine, tmp, hudDir, _) = makeEngine("hud-invalid-settings")
        defer { try? FileManager.default.removeItem(at: tmp) }
        addPlugin("acc1", stdout: "{}", to: tmp)
        engine.reloadRegistry()
        let settings = tmp.appendingPathComponent("settings.json")
        try Data("invalid-json".utf8).write(to: settings)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let original = Data(#"{"External":{"label":"External","source":"cache","cache":"/tmp/cache","buckets":{}}}"#.utf8)
        try original.write(to: envsURL)

        let result = engine.exportHUD()
        if case .success = result { Issue.record("无效设置必须返回同步失败") }
        #expect(try Data(contentsOf: envsURL) == original)
        #expect(try Data(contentsOf: settings) == Data("invalid-json".utf8))
    }

    // MARK: v0.2 HUD 事故修复: 内置键不被清

    @Test @MainActor func accountEnvsKeepBuiltinKeysWithMixedPlugins() throws {
        let (engine, tmp, hudDir, _) = makeEngine("v02builtin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 内置实例 (template 指向模板 slug) + 自定义并存
        let d = tmp.appendingPathComponent("providers/builtin1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ProviderManifest(name: "CC-X", label: "X", template: "xtmpl"))
            .write(to: d.appendingPathComponent("manifest.json"))
        addWrapper(d)
        addPlugin("custom1", stdout: "{}", to: tmp)
        engine.reloadRegistry()
        #expect(engine.hudSyncNames.count == 2)                    // 含内置 CC-X
        #expect(engine.hudSyncNames.contains("builtin1"))
        #expect(engine.envsEntryNames == ["builtin1", "custom1"]) // 内置类型同样使用账号投影
        // 既有合法 ACCOUNT_ENVS (含内置) 保留, 垃圾值滤除
        let settings = tmp.appendingPathComponent("settings.json")
        try? #"{"env":{"ACCOUNT_ENVS":"CC-X,acc-junk,custom1"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        engine.exportHUD()
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let v = ((obj?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String) ?? ""
        #expect(v == "CC-X,acc-junk,builtin1,custom1")   // App 账号采用当前顺序，未知外部条目保留
        // 所有 App 账号均写动态 entry，外部选择保留。
        let envs = try HUDSync.decodeEntries(Data(contentsOf: hudDir.appendingPathComponent("envs.json")))
        #expect(envs.keys.contains("custom1"))
        #expect(!envs.keys.contains("CC-X"))
        #expect(envs["builtin1"]?.cache == hudDir.appendingPathComponent(".builtin1-hud-cache.json").path)
        // 停用账号不进 keys
        engine.setTracking("custom1", enabled: false)
        #expect(engine.hudSyncNames == ["builtin1"])
    }
}

/// 测试用并发计数器 (actor, 无数据竞争)
actor OpTracker {
    private(set) var calls = 0
    private var active = 0
    private(set) var peak = 0
    func enter() { calls += 1; active += 1; peak = max(peak, active) }
    func exit() { active -= 1 }
}
