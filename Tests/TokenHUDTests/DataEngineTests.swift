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
}
