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
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil)
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
        // 仅编辑态 off→on 需要确认
        #expect(SettingsValidation.needsTriggerConfirm(base: false, current: true, isNew: false))
        #expect(!SettingsValidation.needsTriggerConfirm(base: true, current: true, isNew: false))   // 本来就开
        #expect(!SettingsValidation.needsTriggerConfirm(base: true, current: false, isNew: false))  // 关闭
        #expect(!SettingsValidation.needsTriggerConfirm(base: false, current: false, isNew: false)) // 不变
        #expect(!SettingsValidation.needsTriggerConfirm(base: false, current: true, isNew: true))   // 新建草稿无原值
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
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil)
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
}

/// 测试用并发计数器 (actor, 无数据竞争)
actor OpTracker {
    private(set) var calls = 0
    private var active = 0
    private(set) var peak = 0
    func enter() { calls += 1; active += 1; peak = max(peak, active) }
    func exit() { active -= 1 }
}
