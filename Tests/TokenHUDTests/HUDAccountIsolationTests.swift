import Foundation
import Testing
@testable import QuotaNest

@Suite
struct HUDAccountIsolationTests {
    private func account(_ slug: String, name: String = "CC-GLM", displayName: String,
                         template: String? = "glm", hud: URL) -> PluginProvider {
        HUDFixtures.writeWrapper(hud.appendingPathComponent(slug))
        return PluginProvider(slug: slug,
            manifest: ProviderManifest(name: name, label: "GLM", displayName: displayName,
                                       buckets: ["five_hour": "5h"],
                                       cacheFile: hud.appendingPathComponent(".\(slug)-usage-cache.json").path,
                                       template: template), dir: hud.appendingPathComponent(slug))
    }

    @Test func repeatedTypeNamesProduceIndependentHUDEntries() {
        let hud = URL(fileURLWithPath: "/tmp/tokenhud-isolation")
        let plugins = [account("glm", displayName: "主账号", hud: hud),
                       account("glm-second", displayName: "备用账号", hud: hud)]
        let entries = HUDSync.envsDict(plugins: plugins, hudDir: hud, builtinNames: ["CC-GLM"])
        #expect(Set(entries.keys) == ["glm", "glm-second"])
        #expect(entries["glm"]?.label == "主账号")
        #expect(entries["glm-second"]?.label == "备用账号")
        #expect(entries["glm"]?.cache != entries["glm-second"]?.cache)
    }

    @Test func syncMigratesLegacySelectionAndPreservesExternalEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-accounts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"env":{"ACCOUNT_ENVS":"Claude-Max,CC-GLM,external"},"theme":"dark"}"#.utf8).write(to: settings)
        try HUDSync.writeEnvs(["external": EnvsEntry(label: "External", source: "cache", cache: "/external", buckets: [:])],
                              to: root.appendingPathComponent("envs.json"))
        let plugins = [account("glm", displayName: "主账号", hud: root),
                       account("glm-second", displayName: "备用账号", hud: root)]
        try HUDSync.sync(plugins: plugins, hiddenSlugs: [], disabledSlugs: [], hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let env = object?["env"] as? [String: Any]
        #expect(env?["ACCOUNT_ENVS"] as? String == "Claude-Max,glm,external,glm-second")
        #expect(object?["theme"] as? String == "dark")
        var entries = try HUDSync.decodeEntries(Data(contentsOf: root.appendingPathComponent("envs.json")))
        #expect(entries["external"]?.cache == "/external")
        #expect(entries["glm"] != nil && entries["glm-second"] != nil)
        try HUDSync.sync(plugins: plugins, hiddenSlugs: ["glm"], disabledSlugs: [], hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        entries = try HUDSync.decodeEntries(Data(contentsOf: root.appendingPathComponent("envs.json")))
        #expect(entries["glm"] == nil)
        #expect(entries["glm-second"] != nil)
        #expect(entries["external"] != nil)
    }

    @Test @MainActor func generatedLegacyBillingMigrationPreservesModelConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-billing-\(UUID())")
        let providers = root.appendingPathComponent("providers")
        let hud = root.appendingPathComponent("hud")
        let directory = providers.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = hud.appendingPathComponent(".legacy-usage-auth.json")
        let manifest = ProviderManifest(name: "Legacy", label: "Legacy", authFile: auth.path,
                                        queryUrl: "https://api.invalid", refreshUrl: "https://api.invalid/v1/messages",
                                        refreshProtocol: "anthropic")
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        let oldScript = "#!/bin/zsh\n# TokenHUD 生成: one-api\n# billing/subscription\nexit 1\n"
        try oldScript.write(to: directory.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["headers": ["Authorization": "Bearer fixture-query-key"],
            "refreshApiKey": "fixture-model-key", "testModel": "fixture-model", "testPrompt": "fixture-prompt",
            "scheduleTimes": ["09:00"], "customField": "preserved"])
            .write(to: auth)
        let handWritten = providers.appendingPathComponent("handwritten")
        try FileManager.default.createDirectory(at: handWritten, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProviderManifest(name: "Handwritten", label: "Handwritten"))
            .write(to: handWritten.appendingPathComponent("manifest.json"))
        try "#!/bin/zsh\necho '{}'\n".write(to: handWritten.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: hud),
                                defaults: UserDefaults(suiteName: "migration-\(UUID())")!)
        engine.migrateAccounts()
        let migrated = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let config = ProviderConfigStore.read(authFile: auth, manifest: migrated)
        #expect(migrated.quotaMode == "none" && migrated.queryUrl == nil)
        #expect(config.queryUrl.isEmpty)
        #expect(config.apiBaseURL == "https://api.invalid")
        #expect(config.refreshUrl == manifest.refreshUrl)
        #expect(config.refreshKey == "fixture-model-key")
        #expect(config.testModel == "fixture-model" && config.testPrompt == "fixture-prompt")
        #expect(config.scheduleTimes == ["09:00"])
        let storedAuth = try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any]
        #expect(storedAuth?["customField"] as? String == "preserved")
        #expect(try String(contentsOf: directory.appendingPathComponent("fetch.sh"), encoding: .utf8).contains("generic-usage-provider.mjs"))
        let unchanged = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: handWritten.appendingPathComponent("manifest.json")))
        #expect(unchanged.quotaMode == nil)
        let once = try Data(contentsOf: auth)
        engine.migrateAccounts()
        #expect(try Data(contentsOf: auth) == once)
    }

    @Test @MainActor func localIdentityFailureCannotRestoreAnotherAccountsSnapshot() async throws {
        for incoming in ["B", "", "A", "exit1", "non-json"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-error-\(UUID())")
            let providers = root.appendingPathComponent("providers")
            let hud = root.appendingPathComponent("hud")
            let directory = providers.appendingPathComponent("local")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let manifest = ProviderManifest(name: "Local", label: "Local", queryAuth: "header")
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
            let old = UsageCache(generatedAt: 123, sevenDay: Bucket(usedPercentage: 17), accountId: "A")
            try JSONEncoder().encode(old).write(to: hud.appendingPathComponent(".local-usage-cache.json"))
            var failure: [String: Any] = ["error": "auth"]
            if !incoming.isEmpty { failure["account_id"] = incoming }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: failure), as: UTF8.self)
            let script = incoming == "exit1" ? "#!/bin/zsh\nexit 1\n"
                : (incoming == "non-json" ? "#!/bin/zsh\necho not-json\n" : "#!/bin/zsh\necho '\(body)'\n")
            try script.write(to: directory.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
            let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                    runner: ProviderRunner(nodePath: nil, logDir: hud),
                                    defaults: UserDefaults(suiteName: "identity-\(UUID())")!)
            engine.reloadRegistry()
            _ = await engine.forceRefresh(slug: "local")
            let snapshot = engine.states.first?.cache
            if incoming == "A" {
                #expect(snapshot?.sevenDay?.usedPercentage == 17)
                #expect(snapshot?.generatedAt == 123)
            } else {
                #expect(snapshot?.sevenDay == nil, "Changed or absent identity must clear old quota")
            }
            if incoming == "exit1" || incoming == "non-json" {
                #expect(snapshot?.accountId == nil)
                #expect(snapshot?.generatedAt == nil)
                #expect(snapshot?.error == (incoming == "exit1" ? "process-exit-1" : "invalid-response"))
                let disk = try JSONDecoder().decode(UsageCache.self, from: Data(contentsOf: hud.appendingPathComponent(".local-usage-cache.json")))
                #expect(disk.accountId == nil && disk.sevenDay == nil)
            }
            #expect(engine.states.first?.isStale == true)
        }
    }

    @Test func credentialRevisionsDoNotShareInFlightResults() async throws {
        let gate = QueryGate(globalLimit: 3, waitBudgetSec: 2)
        let fixture = QueryRevisionFixture()
        let first = Task {
            try await gate.run(slug: "same-account", revision: 1) {
                await fixture.holdFirst()
                return UsageCache(sevenDay: Bucket(usedPercentage: 10))
            }
        }
        await fixture.waitUntilFirstStarted()
        let second = Task {
            try await gate.run(slug: "same-account", revision: 2) {
                await fixture.markSecondStarted()
                return UsageCache(sevenDay: Bucket(usedPercentage: 80))
            }
        }
        // A is held by a controlled continuation while B reaches the gate.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await fixture.secondStarted == false, "Same-account operations must remain serialized")
        await fixture.releaseFirst()
        let a = try await first.value
        let b = try await second.value
        #expect(a?.sevenDay?.usedPercentage == 10)
        #expect(b?.sevenDay?.usedPercentage == 80, "B must execute using its own credentials, not receive A's result")
        #expect(await fixture.secondStarted)
    }

    @Test func explicitQuotaCapabilityGatesExecution() {
        var manifest = ProviderManifest(name: "custom", label: "Custom")
        #expect(DataEngine.canQuery(manifest), "Legacy custom fetch plugins remain compatible")
        manifest.quotaMode = "none"
        manifest.queryUrl = "https://quota.invalid/exact"
        #expect(!DataEngine.canQuery(manifest))
        manifest.quotaMode = "endpoint"
        #expect(DataEngine.canQuery(manifest))
        manifest.queryUrl = "  "
        #expect(!DataEngine.canQuery(manifest))
    }

    @Test @MainActor func disabledQuotaDoesNotLaunchFetchOrCreateCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-query-\(UUID())")
        let providers = root.appendingPathComponent("providers")
        let hud = root.appendingPathComponent("hud")
        let plugin = providers.appendingPathComponent("model-only")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = ProviderManifest(name: "Model only", label: "Model")
        manifest.quotaMode = "none"
        try JSONEncoder().encode(manifest).write(to: plugin.appendingPathComponent("manifest.json"))
        let sentinel = root.appendingPathComponent("unexpected-query")
        try "#!/bin/zsh\ntouch '\(sentinel.path)'\necho '{\"seven_day\":{\"used_percentage\":1}}'\n"
            .write(to: plugin.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "no-query-\(UUID())")!
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults)
        engine.reloadRegistry()
        await engine.refreshNow()
        let result = await engine.forceRefresh(slug: "model-only")
        #expect(!result.ok)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent(".model-only-usage-cache.json").path))
    }
}

private actor QueryRevisionFixture {
    private var release: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var secondStarted = false

    func holdFirst() async {
        await withCheckedContinuation { continuation in
            release = continuation
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitUntilFirstStarted() async {
        if release != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseFirst() {
        release?.resume()
        release = nil
    }

    func markSecondStarted() { secondStarted = true }
}
