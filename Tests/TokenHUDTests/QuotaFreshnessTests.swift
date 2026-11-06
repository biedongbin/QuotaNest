import Foundation
import Combine
import Testing
@testable import QuotaNest

@Suite
struct QuotaFreshnessTests {
    @Test func displayGraceDoesNotExtendSchedulingOrStrictFreshness() {
        let cache = UsageCache(generatedAt: 1_000_000, lastAttemptAt: 1_000_000)
        #expect(HUDFmt.isDisplayFresh(cache, interval: 60, now: 1_061_000))
        #expect(!HUDFmt.isFresh(cache, interval: 60, now: 1_061_000))
        #expect(!HUDFmt.isAttemptFresh(cache, interval: 60, now: 1_060_000))
        #expect(HUDFmt.isDisplayFresh(cache, interval: 60, now: 1_119_999))
        #expect(!HUDFmt.isDisplayFresh(cache, interval: 60, now: 1_120_000))
    }

    @Test func errorsStaleAndMissingSuccessNeverGetDisplayGrace() {
        let now = 1_000_000.0
        #expect(!HUDFmt.isDisplayFresh(nil, interval: 60, now: now))
        #expect(!HUDFmt.isDisplayFresh(UsageCache(lastAttemptAt: now), interval: 60, now: now))
        #expect(!HUDFmt.isDisplayFresh(UsageCache(generatedAt: now, error: "fetch"), interval: 60, now: now))
        #expect(!HUDFmt.isDisplayFresh(UsageCache(generatedAt: now, stale: true), interval: 60, now: now))
        #expect(HUDFmt.isDisplayFresh(UsageCache(generatedAt: now, stale: false), interval: 60, now: now))
    }

    @Test func displayIntervalClampsMinimumAndCannotOverflowInt() {
        let cache = UsageCache(generatedAt: 0)
        #expect(HUDFmt.isDisplayFresh(cache, interval: 0, now: 1_999))
        #expect(!HUDFmt.isDisplayFresh(cache, interval: -60, now: 2_000))
        #expect(HUDFmt.isDisplayFresh(cache, interval: Int.max, now: 1_000_000))
        let boundary = Double(Int.max) * 2 * 1_000
        #expect(!HUDFmt.isDisplayFresh(cache, interval: Int.max, now: boundary))
    }

    @MainActor
    private func fixture(slugs: [String] = ["account"]) throws -> (DataEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-freshness-\(UUID())")
        let providers = root.appendingPathComponent("providers")
        let hud = root.appendingPathComponent("privateHUD")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        for slug in slugs {
            let dir = providers.appendingPathComponent(slug)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let auth = hud.appendingPathComponent(".\(slug)-usage-auth.json")
            let manifest = ProviderManifest(name: slug, label: slug, intervalSec: 60,
                cacheFile: hud.appendingPathComponent(".\(slug)-usage-cache.json").path, authFile: auth.path)
            try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
            try Data("{}".utf8).write(to: auth)
        }
        let defaults = try #require(UserDefaults(suiteName: "quota-freshness-\(UUID())"))
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
            settingsURL: root.appendingPathComponent("settings.json"))
        engine.quotaRetrySleep = { _ in }
        engine.reloadRegistry()
        return (engine, root)
    }

    @MainActor
    private func seed(_ cache: UsageCache, slug: String, root: URL) throws {
        try JSONEncoder().encode(cache).write(to: cacheURL(slug, root: root))
    }

    private func cacheURL(_ slug: String, root: URL) -> URL {
        root.appendingPathComponent("privateHUD/.\(slug)-usage-cache.json")
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func fastAccountPublishesToDiskAndMemoryBeforeSlowAccountCompletes() async throws {
        let (engine, root) = try fixture(slugs: ["fast", "slow"])
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSuccess = Date().timeIntervalSince1970 * 1_000 - 61_000
        for slug in ["fast", "slow"] {
            try seed(UsageCache(generatedAt: oldSuccess, sevenDay: Bucket(usedPercentage: 5)), slug: slug, root: root)
        }
        engine.reloadRegistry()
        #expect(engine.states.allSatisfy { !$0.isStale })
        let control = FreshnessAttempts()
        engine.quotaAttempt = { await control.response(for: $0.slug) }
        let published = FreshnessSignal()
        let observation = engine.$lastRefresh.sink { value in
            if value != nil { Task { await published.signal() } }
        }
        defer { observation.cancel() }
        let round = Task { await engine.refreshNow() }
        await control.waitUntilStarted("fast")
        await control.waitUntilStarted("slow")
        #expect(engine.queryingSlugs == Set(["fast", "slow"]))
        let success = Date().timeIntervalSince1970 * 1_000
        control.finish("fast", with: UsageCache(generatedAt: success, sevenDay: Bucket(usedPercentage: 42)))
        await published.wait()
        // The slow continuation is still held while the fast account is already committed.
        #expect(control.isPending("slow"))
        #expect(engine.states.first(where: { $0.slug == "fast" })?.cache?.sevenDay?.usedPercentage == 42)
        #expect(engine.states.first(where: { $0.slug == "fast" })?.cache?.generatedAt == success)
        #expect(engine.states.first(where: { $0.slug == "slow" })?.cache?.generatedAt == oldSuccess)
        #expect(engine.queryingSlugs == Set(["slow"]))
        let disk = try JSONDecoder().decode(UsageCache.self, from: Data(contentsOf: cacheURL("fast", root: root)))
        #expect(disk.sevenDay?.usedPercentage == 42 && disk.generatedAt == success)
        control.finish("slow", with: UsageCache(generatedAt: success, sevenDay: Bucket(usedPercentage: 17)))
        await round.value
        #expect(engine.queryingSlugs.isEmpty)
        #expect(await engine.queryGate.inFlightSlugs.isEmpty)
    }

    @Test @MainActor func displayGraceStillQueriesAtOneMinute() async throws {
        let (engine, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let success = Date().timeIntervalSince1970 * 1_000 - 61_000
        try seed(UsageCache(generatedAt: success, sevenDay: Bucket(usedPercentage: 5)), slug: "account", root: root)
        engine.reloadRegistry()
        #expect(engine.states.first?.isStale == false)
        var attempts = 0
        engine.quotaAttempt = { _ in
            attempts += 1
            #expect(engine.queryingSlugs.contains("account"))
            #expect(engine.states.first?.isStale == false)
            return UsageCache(generatedAt: success + 61_000, sevenDay: Bucket(usedPercentage: 42))
        }
        await engine.refreshNow()
        #expect(attempts == 1)
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 42)
        #expect(engine.queryingSlugs.isEmpty)
    }

    @Test @MainActor func queryingSpansRetriesAndKeepsFailureUntilFinalResult() async throws {
        let (engine, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let success = Date().timeIntervalSince1970 * 1_000
        try seed(UsageCache(generatedAt: success, sevenDay: Bucket(usedPercentage: 73), error: "auth", stale: true),
            slug: "account", root: root)
        engine.reloadRegistry()
        var attempts = 0, delays = 0
        engine.quotaRetrySleep = { _ in
            delays += 1
            #expect(engine.queryingSlugs.contains("account"))
        }
        engine.quotaAttempt = { _ in
            attempts += 1
            #expect(engine.queryingSlugs.contains("account"))
            #expect(engine.states.first?.cache?.error == "auth")
            #expect(engine.states.first?.isStale == true)
            return UsageCache(error: "fetch", stale: true)
        }
        let outcome = await engine.forceRefresh(slug: "account")
        #expect(!outcome.ok && attempts == 3 && delays == 2)
        #expect(engine.queryingSlugs.isEmpty)
        #expect(engine.states.first?.cache?.error == "fetch")
        #expect(engine.states.first?.cache?.generatedAt == success)
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 73)
        #expect(engine.states.first?.isStale == true)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func cancellingBackgroundBackoffClearsQueryingWithoutAdvancingAttempt() async throws {
        let (engine, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let success = Date().timeIntervalSince1970 * 1_000 - 61_000
        let previous = UsageCache(generatedAt: success, sevenDay: Bucket(usedPercentage: 73))
        try seed(previous, slug: "account", root: root)
        let before = try Data(contentsOf: cacheURL("account", root: root))
        engine.reloadRegistry()
        let backoff = FreshnessSignal()
        var attempts = 0
        engine.quotaAttempt = { _ in attempts += 1; return UsageCache(error: "fetch") }
        engine.quotaRetrySleep = { _ in
            await backoff.signal()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let round = Task { await engine.refreshNow() }
        await backoff.wait()
        #expect(engine.queryingSlugs == Set(["account"]))
        round.cancel()
        await round.value
        #expect(attempts == 1)
        #expect(engine.queryingSlugs.isEmpty)
        #expect(await engine.queryGate.inFlightSlugs.isEmpty)
        #expect(engine.states.first?.cache?.lastAttemptAt == nil)
        #expect(try Data(contentsOf: cacheURL("account", root: root)) == before)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func changedSourceDiscardsLateBackgroundResultAndClearsQuerying() async throws {
        let (engine, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json")
        func writeSource(_ key: String) throws {
            try JSONSerialization.data(withJSONObject: ["type": "clinepass", "api_key": key,
                "base_url": "https://quota.invalid/v1"]).write(to: source)
        }
        try writeSource("offline-old")
        let reference = ProviderSourceReference(source: "cpamp", path: source.path,
            recordId: source.lastPathComponent, providerId: "clinepass")
        var manifest = try #require(engine.allPlugins.first?.manifest)
        manifest.sourceReference = reference
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("providers/account/manifest.json"))
        let oldRevision = try ImportedSource.read(reference).revision
        let old = UsageCache(generatedAt: Date().timeIntervalSince1970 * 1_000 - 61_000,
            sevenDay: Bucket(usedPercentage: 5), sourceRevision: oldRevision)
        try seed(old, slug: "account", root: root)
        let before = try Data(contentsOf: cacheURL("account", root: root))
        engine.reloadRegistry()
        let control = FreshnessAttempts()
        engine.quotaAttempt = { await control.response(for: $0.slug) }
        let round = Task { await engine.refreshNow() }
        await control.waitUntilStarted("account")
        #expect(engine.queryingSlugs == Set(["account"]))
        try writeSource("offline-new")
        control.finish("account", with: UsageCache(generatedAt: 9_999_999,
            sevenDay: Bucket(usedPercentage: 99), sourceRevision: oldRevision))
        await round.value
        #expect(engine.queryingSlugs.isEmpty)
        #expect(control.attemptCount == 1)
        #expect(engine.states.first?.cache == nil)
        #expect(try Data(contentsOf: cacheURL("account", root: root)) == before)
        #expect(engine.lastRefresh == nil)
    }

    @Test @MainActor func disabledBackgroundAccountDoesNotStartQuerying() async throws {
        let (engine, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        engine.quotaAttempt = { _ in attempts += 1; return UsageCache(generatedAt: 1) }
        engine.setTracking("account", enabled: false)
        await engine.refreshNow()
        #expect(attempts == 0)
        #expect(engine.queryingSlugs.isEmpty)
    }
}

@MainActor
private final class FreshnessAttempts {
    private var pending: [String: CheckedContinuation<UsageCache?, Never>] = [:]
    private var started: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var attemptCount = 0

    func response(for slug: String) async -> UsageCache? {
        attemptCount += 1
        return await withCheckedContinuation { continuation in
            pending[slug] = continuation
            started.insert(slug)
            for waiter in waiters.removeValue(forKey: slug) ?? [] { waiter.resume() }
        }
    }

    func waitUntilStarted(_ slug: String) async {
        if started.contains(slug) { return }
        await withCheckedContinuation { waiters[slug, default: []].append($0) }
    }

    func isPending(_ slug: String) -> Bool { pending[slug] != nil }

    func finish(_ slug: String, with cache: UsageCache) {
        pending.removeValue(forKey: slug)?.resume(returning: cache)
    }
}

private actor FreshnessSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
