import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized) @MainActor
struct MenuBarMetricSelectionTests {
    @MainActor private struct Fixture {
        let root: URL
        let hud: URL
        let defaults: UserDefaults
        let suite: String
        let engine: DataEngine
        var cache: URL { hud.appendingPathComponent(".account-usage-cache.json") }
        func newEngine() -> DataEngine {
            DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: root.appendingPathComponent("providers"),
                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                settingsURL: root.appendingPathComponent("settings.json"))
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-metric-\(UUID())")
        let hud = root.appendingPathComponent("hud"), provider = root.appendingPathComponent("providers/account")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        let cache = hud.appendingPathComponent(".account-usage-cache.json")
        try JSONEncoder().encode(ProviderManifest(name: "Account", label: "Account", cacheFile: cache.path))
            .write(to: provider.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000,
            fiveHour: Bucket(usedPercentage: 9), sevenDay: Bucket(usedPercentage: 83), monthly: Bucket(usedPercentage: 37))).write(to: cache)
        let suite = "menu-metric.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: root.appendingPathComponent("providers"),
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: isolated, settingsURL: root.appendingPathComponent("settings.json"))
        engine.reloadRegistry()
        return Fixture(root: root, hud: hud, defaults: isolated, suite: suite, engine: engine)
    }

    @Test func choosingPeriodUsesItsValueAndSurvivesRestart() throws {
        let f = try fixture(); defer { f.cleanup() }
        #expect(f.engine.menuBarMetric?.percentage == 83)
        #expect(f.engine.setIconMetric(provider: "account", key: "monthly"))
        #expect(f.engine.menuBarMetric?.percentage == 37)
        #expect(f.engine.menuBarMetric?.selectionKey == "monthly")
        let restarted = f.newEngine(); restarted.reloadRegistry()
        #expect(restarted.iconProviderSlug == "account")
        #expect(restarted.iconMetricKey == "monthly")
        #expect(restarted.menuBarMetric?.percentage == 37)
        #expect(f.engine.setIconMetric(provider: "account", key: "five_hour"))
        #expect(f.engine.menuBarMetric?.percentage == 9)
    }

    @Test func selectedPeriodDoesNotSilentlyFallBackWhenMissing() throws {
        let f = try fixture(); defer { f.cleanup() }
        #expect(f.engine.setIconMetric(provider: "account", key: "monthly"))
        try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000,
            sevenDay: Bucket(usedPercentage: 94))).write(to: f.cache)
        f.engine.reloadRegistry()
        #expect(f.engine.menuBarProviderSlug == "account")
        #expect(f.engine.menuBarMetric == nil)
        #expect(f.engine.iconMetricKey == "monthly")
        f.engine.setIconProvider(nil)
        #expect(f.engine.iconMetricKey == nil)
        #expect(f.engine.menuBarMetric?.percentage == 94)
    }

    @Test func keysRemainStableAcrossAdapterFormatAndWindowOrderChanges() throws {
        let f = try fixture(); defer { f.cleanup() }
        #expect(f.engine.setIconMetric(provider: "account", key: "monthly"))
        let month = WindowBucket(label: "本月", usedPercentage: 41, period: "monthly")
        let week = WindowBucket(label: "本周", usedPercentage: 95, period: "7天")
        for windows in [[month, week], [week, month]] {
            try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000, windows: windows)).write(to: f.cache)
            f.engine.reloadRegistry()
            #expect(f.engine.menuBarMetric?.percentage == 41)
            #expect(f.engine.menuBarMetric?.selectionKey == "monthly")
        }
        #expect(WindowBucket(label: "This month", period: "monthly").menuBarSelectionKey == month.menuBarSelectionKey)
        #expect(WindowBucket(label: "Sonnet", period: "weekly").menuBarSelectionKey != WindowBucket(label: "All models", period: "weekly").menuBarSelectionKey)
    }

    @Test func invalidSelectionDoesNotChangeSavedChoice() throws {
        let f = try fixture(); defer { f.cleanup() }
        #expect(f.engine.setIconMetric(provider: "account", key: "monthly"))
        #expect(!f.engine.setIconMetric(provider: "account", key: "nonexistent"))
        #expect(!f.engine.setIconMetric(provider: "missing", key: "monthly"))
        #expect(f.engine.menuBarMetric?.percentage == 37)
        #expect(f.defaults.string(forKey: DataEngine.defaultsIconMetricKey) == "monthly")
    }
}
