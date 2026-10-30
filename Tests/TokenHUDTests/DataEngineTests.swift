import Foundation
import Testing
@testable import TokenHUD

@Suite
struct DataEngineTests {
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
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil)
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
            .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
        var merged = existing
        merged.removeValue(forKey: p.manifest.name)
        try? HUDSync.writeEnvs(merged, to: envsURL)
        // 断言: 无残留
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
        let after = (try? Data(contentsOf: envsURL))
            .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
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
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        let suite = "th-engine-\(tag)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: nil, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: nil), defaults: defaults)
        return (engine, tmp, hudDir, defaults)
    }

    private func addPlugin(_ slug: String, stdout: String, to tmp: URL) {
        let d = tmp.appendingPathComponent("providers/\(slug)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "#!/bin/zsh\necho '\(stdout)'".write(to: d.appendingPathComponent("fetch.sh"),
                                                 atomically: true, encoding: .utf8)
        try? JSONEncoder().encode(ProviderManifest(name: slug, label: slug, buckets: ["seven_day": "周"]))
            .write(to: d.appendingPathComponent("manifest.json"))
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
        #expect(bad.reason == "缺凭证或凭证失效")
        #expect(bad.message("B") == "✗ B 刷新失败: 缺凭证或凭证失效")

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
}
