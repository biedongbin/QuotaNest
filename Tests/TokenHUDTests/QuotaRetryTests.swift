import Foundation
import Testing
@testable import QuotaNest

@Suite
struct QuotaRetryTests {
    @MainActor
    private func fixture(interval: Int = 3600) throws -> (DataEngine, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-retry-\(UUID())")
        let providers = root.appendingPathComponent("providers")
        let dir = providers.appendingPathComponent("account")
        let hud = root.appendingPathComponent("hud")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        let manifest = ProviderManifest(name: "Account", label: "A", intervalSec: interval,
            authFile: hud.appendingPathComponent(".account-usage-auth.json").path)
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let defaults = try #require(UserDefaults(suiteName: "quota-retry-\(UUID())"))
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults)
        engine.quotaRetrySleep = { _ in }
        engine.reloadRegistry()
        return (engine, root, defaults)
    }

    @Test @MainActor func effectiveIntervalCapsLegacyValuesAndPreservesShortIntervals() throws {
        let (engine, root, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try #require(engine.allPlugins.first?.manifest)
        #expect(engine.effectiveIntervalSeconds("account", manifest: manifest) == 300)
        defaults.set(Int.max, forKey: DataEngine.intervalKey("account"))
        #expect(engine.effectiveIntervalSeconds("account", manifest: manifest) == 300)
        defaults.set(2, forKey: DataEngine.intervalKey("account"))
        #expect(engine.effectiveIntervalSeconds("account", manifest: manifest) == 120)
        engine.clearIntervalOverride("account")
        manifest.intervalSec = 30
        #expect(engine.effectiveIntervalSeconds("account", manifest: manifest) == 30)
        engine.setIntervalMinutes("account", minutes: 60)
        #expect(defaults.integer(forKey: DataEngine.intervalKey("account")) == 5)
        #expect(DataEngine.rateLimitPauseMs(intervalSec: 3600) == 300_000)
    }

    @Test @MainActor func legacyHourOverrideIsDueAfterFiveMinutes() async throws {
        let (engine, root, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(60, forKey: DataEngine.intervalKey("account"))
        let cache = UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000 - 301_000,
            sevenDay: Bucket(usedPercentage: 12))
        try JSONEncoder().encode(cache).write(to: root.appendingPathComponent("hud/.account-usage-cache.json"))
        engine.reloadRegistry()
        // Refresh is already due, while display freshness still has one cycle of grace.
        #expect(engine.states.first?.isStale == false)
        var count = 0
        engine.quotaAttempt = { _ in
            count += 1
            return UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000, sevenDay: Bucket(usedPercentage: 42))
        }
        await engine.refreshNow()
        #expect(count == 1)
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 42)
    }

    @Test @MainActor func firstTwoFailuresThenSuccessPublishesOnlyFinalSuccess() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        var delays: [UInt64] = []
        engine.quotaRetrySleep = { delays.append($0) }
        engine.quotaAttempt = { _ in
            attempts += 1
            #expect(engine.states.first?.cache == nil)
            return attempts < 3 ? UsageCache(error: "auth", stale: true)
                : UsageCache(generatedAt: 9000, sevenDay: Bucket(usedPercentage: 31))
        }
        let outcome = await engine.forceRefresh(slug: "account")
        #expect(outcome.ok)
        #expect(attempts == 3)
        #expect(delays == [1_000_000_000, 2_000_000_000])
        #expect(engine.states.first?.cache?.generatedAt == 9000)
        #expect(engine.states.first?.cache?.error == nil)
        #expect(engine.queryDiagnostics["account"]?.retryCount == 2)
    }

    @Test @MainActor func threeFailuresPreserveOldSnapshotAndRecordFinalReason() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("hud/.account-usage-cache.json")
        let old = UsageCache(generatedAt: 1234, sevenDay: Bucket(usedPercentage: 73))
        try JSONEncoder().encode(old).write(to: path)
        engine.reloadRegistry()
        var count = 0
        engine.quotaAttempt = { _ in
            count += 1
            return UsageCache(error: count == 3 ? "ratelimit" : "fetch", stale: true)
        }
        let result = await engine.forceRefresh(slug: "account")
        let state = try #require(engine.states.first)
        #expect(!result.ok && result.reason.contains("已重试 2 次"))
        #expect(count == 3)
        #expect(state.cache?.sevenDay?.usedPercentage == 73)
        #expect(state.cache?.generatedAt == 1234)
        #expect(state.cache?.lastAttemptAt ?? 0 > 1234)
        #expect(state.cache?.error == "ratelimit" && state.isStale)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(object["queryAttemptCount"] as? Int == 3)
        #expect(object["queryRetryCount"] as? Int == 2)
        #expect(object["queryFinalError"] as? String == "ratelimit")
        engine.reloadRegistry()
        #expect(engine.states.first?.isStale == true)
    }

    @Test @MainActor func syntheticFailuresKeepAccountSnapshotOnlyForTheSameLiveSource() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json")
        try JSONSerialization.data(withJSONObject: ["type": "clinepass", "api_key": "quota-test-key",
            "base_url": "https://quota.invalid/v1"]).write(to: source)
        let reference = ProviderSourceReference(source: "cpamp", path: source.path,
            recordId: source.lastPathComponent, providerId: "clinepass")
        var manifest = try #require(engine.allPlugins.first?.manifest)
        manifest.sourceReference = reference
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("providers/account/manifest.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("hud/.account-usage-auth.json"))
        let revision = try ImportedSource.read(reference).revision
        let path = root.appendingPathComponent("hud/.account-usage-cache.json")
        let old = UsageCache(generatedAt: 1234, sevenDay: Bucket(usedPercentage: 73),
            accountId: "account-A", sourceRevision: revision)
        try JSONEncoder().encode(old).write(to: path)
        engine.reloadRegistry()
        var attempts = 0
        let errors = ["process-launch", "timeout", "invalid-response"]
        engine.quotaAttempt = { _ in
            attempts += 1
            return UsageCache(error: errors[attempts - 1], stale: true, sourceRevision: revision)
        }
        let result = await engine.forceRefresh(slug: "account")
        #expect(!result.ok && attempts == 3)
        let saved = try JSONDecoder().decode(UsageCache.self, from: Data(contentsOf: path))
        #expect(saved.sevenDay?.usedPercentage == 73 && saved.generatedAt == 1234)
        #expect(saved.accountId == "account-A" && saved.sourceRevision == revision)
        #expect(saved.error == "invalid-response" && saved.stale == true)
        #expect(saved.lastAttemptAt ?? 0 > 1234)
        #expect(engine.states.first?.cache?.accountId == "account-A")
        #expect(engine.states.first?.isStale == true)
        #expect(engine.queryDiagnostics["account"]?.attemptCount == 3)

        // Even the same source revision cannot authorize an explicit different response identity.
        engine.quotaAttempt = { _ in
            UsageCache(error: "auth", stale: true, accountId: "account-B", sourceRevision: revision)
        }
        _ = await engine.forceRefresh(slug: "account")
        #expect(engine.states.first?.cache?.accountId == "account-B")
        #expect(engine.states.first?.cache?.sevenDay == nil)
        #expect(engine.states.first?.cache?.generatedAt == nil)
    }

    @Test @MainActor func cancellationDuringBackoffStopsSequenceAndDoesNotPublishFailure() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = QuotaSignal()
        var count = 0
        engine.quotaAttempt = { _ in count += 1; return UsageCache(error: "fetch") }
        engine.quotaRetrySleep = { _ in
            await started.signal()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let task = Task { await engine.forceRefresh(slug: "account") }
        await started.wait()
        task.cancel()
        let result = await task.value
        #expect(!result.ok && result.reason.contains("取消"))
        #expect(count == 1)
        #expect(engine.states.first?.cache == nil)
        #expect(await engine.queryGate.inFlightSlugs.isEmpty)
    }

    @Test @MainActor func sameAccountJoinsOneEntireRetrySequence() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = QuotaSignal(), release = QuotaSignal()
        var calls = 0, active = 0, peak = 0
        engine.quotaAttempt = { _ in
            calls += 1
            active += 1
            peak = max(peak, active)
            if calls == 1 { await started.signal(); await release.wait() }
            active -= 1
            return calls < 3 ? UsageCache(error: "fetch")
                : UsageCache(generatedAt: 7000, sevenDay: Bucket(usedPercentage: 7))
        }
        let first = Task { await engine.forceRefresh(slug: "account") }
        await started.wait()
        let second = Task { await engine.forceRefresh(slug: "account") }
        try await Task.sleep(nanoseconds: 30_000_000)
        await release.signal()
        let a = await first.value, b = await second.value
        #expect(a.ok && b.ok)
        #expect(calls == 3 && peak == 1)
        #expect(await engine.queryGate.inFlightSlugs.isEmpty)
    }

    @Test @MainActor func credentialChangeWithSameMtimeDiscardsLateResultAndStopsRetries() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("hud/.account-usage-auth.json")
        try Data(#"{"refreshApiKey":"fixture-A"}"#.utf8).write(to: auth)
        let modified = try #require(try auth.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var count = 0
        engine.quotaAttempt = { _ in
            count += 1
            try? Data(#"{"refreshApiKey":"fixture-B"}"#.utf8).write(to: auth)
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: auth.path)
            return UsageCache(generatedAt: 9999, sevenDay: Bucket(usedPercentage: 99))
        }
        let result = await engine.forceRefresh(slug: "account")
        #expect(!result.ok && result.reason.contains("配置已变更"))
        #expect(count == 1)
        #expect(engine.states.first?.cache == nil)
    }

    @Test @MainActor func eachRunnerRetryRecreatesCredentialSnapshot() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try #require(engine.allPlugins.first?.manifest)
        manifest.queryUrl = "https://quota.invalid/usage"
        let auth = root.appendingPathComponent("hud/.account-usage-auth.json")
        let replacement = root.appendingPathComponent("replacement.json")
        try Data(#"{"refreshApiKey":"fixture-A"}"#.utf8).write(to: auth)
        try Data(#"{"refreshApiKey":"fixture-B"}"#.utf8).write(to: replacement)
        let dir = root.appendingPathComponent("providers/account")
        try """
        key=$(/usr/bin/plutil -extract queryKey raw -o - "$TOKENHUD_AUTH_FILE")
        if [[ "$key" == "fixture-A" ]]; then
            /bin/cp '\(replacement.path)' '\(auth.path)'
            print -r -- '{"error":"auth"}'
        elif [[ "$key" == "fixture-B" ]]; then
            print -r -- '{"seven_day":{"used_percentage":21}}'
        else
            exit 4
        fi
        """.write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let runner = ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("hud"))
        let result = await runner.runWithRetries(PluginProvider(slug: "account", manifest: manifest, dir: dir), delay: { _ in })
        #expect(result.attemptCount == 2 && result.retryCount == 1)
        #expect(result.cache?.sevenDay?.usedPercentage == 21)
        #expect(result.failureReason == nil)
    }
    @Test @MainActor func overlappingSchedulerTicksShareOneBackgroundRound() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = QuotaSignal(), release = QuotaSignal()
        var attempts = 0
        engine.quotaAttempt = { _ in
            attempts += 1
            if attempts == 1 { await started.signal(); await release.wait() }
            return UsageCache(error: "fetch")
        }
        let first = Task { await engine.refreshNow() }
        await started.wait()
        await engine.refreshNow()
        #expect(attempts == 1)
        await release.signal()
        await first.value
        #expect(attempts == 3)
    }

    @Test @MainActor func unresolvedCredentialsRetryResolutionWithoutLaunchingScript() async throws {
        let (engine, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try #require(engine.allPlugins.first?.manifest)
        manifest.authMode = "auth"
        manifest.credentialSource = ProviderCredentialSource(file: root.appendingPathComponent("missing-auth.json").path,
            environmentDirectory: nil, tokenPath: "access_token", headerPaths: nil, requiredValues: nil)
        let sentinel = root.appendingPathComponent("unexpected-launch")
        let dir = root.appendingPathComponent("providers/account")
        try "touch '\(sentinel.path)'".write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let runner = ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("hud"))
        let result = await runner.runWithRetries(PluginProvider(slug: "account", manifest: manifest, dir: dir), delay: { _ in })
        #expect(result.attemptCount == 3 && result.retryCount == 2)
        #expect(result.failureReason?.hasPrefix("配置错误：") == true)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}

private actor QuotaSignal {
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
