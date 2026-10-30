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
