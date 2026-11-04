import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct AccountManagementTests {
    private struct Fixture {
        let root: URL
        let hud: URL
        let model: SettingsModel
        let defaults: UserDefaults
        let suite: String
    }

    private func fixture(withTemplate: Bool = false,
                         execute: ((ProviderConfig) async -> String?)? = nil,
                         query: ((String) async -> RefreshOutcome)? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-accounts-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let suite = "tokenhud.accounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let bundle = root.appendingPathComponent("bundle")
        if withTemplate {
            var manifest = ProviderManifest(name: "Fixture", label: "Fixture", testModel: "fixture-model",
                queryUrl: "https://quota.example.test/usage", refreshUrl: "https://api.example.test/v1/messages",
                refreshProtocol: "anthropic", quotaMode: "script")
            manifest.credentialSource = ProviderCredentialSource(file: root.appendingPathComponent("fixture-auth.json").path,
                tokenPath: "session.access_token")
            manifest.authCallUrl = "https://auth.example.test/v1/responses"
            manifest.authCallProtocol = "responses"
            try PluginGenerator.writePlugin(slug: "fixture", manifest: manifest, script: "exit 1", into: bundle)
            try Data("{}".utf8).write(to: bundle.appendingPathComponent("fixture/auth-template.json"))
        }
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: withTemplate ? bundle : nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                                settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: nil, defaults: defaults, confirmDiscardChanges: { true },
                                  confirmResumePlan: { true }, confirmTestCall: { _ in true },
                                  executeTestCall: execute ?? { _ in "✓ offline" },
                                  executeQuotaQuery: query ?? { _ in .ok })
        return Fixture(root: root, hud: hud, model: model, defaults: defaults, suite: suite)
    }

    private func cleanup(_ f: Fixture) {
        f.defaults.removePersistentDomain(forName: f.suite)
        try? FileManager.default.removeItem(at: f.root)
    }

    private func create(_ f: Fixture, quota: Bool = false) throws -> AccountRow {
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "generic-openai" }))
        f.model.draft?.values.name = "Work subscription"
        f.model.draft?.values.url = "https://api.example.test/v1"
        f.model.draft?.values.key = "fixture-api-key"
        f.model.draft?.values.model = "test-model"
        f.model.draft?.values.autoTrigger = true
        f.model.draft?.values.times = ["09:00"]
        if quota {
            f.model.draft?.values.quotaMode = "endpoint"
            f.model.draft?.values.queryURL = "https://quota.example.test/account/usage"
        }
        f.model.save()
        #expect(f.model.topError.isEmpty)
        return try #require(f.model.current)
    }

    @Test func apiOnlyAccountCanKeepItsCallScheduleWithoutQuota() throws {
        let f = try fixture(); defer { cleanup(f) }
        let row = try create(f)
        #expect(row.canCall)
        #expect(!row.canQuery)
        #expect(row.isConfigured)
        #expect(f.model.callConfigured(row))
        #expect(!f.model.quotaConfigured(row))
        #expect(!f.model.engine.triggerDisabledSlugs.contains(row.id))
        let cfg = f.model.readConfig(row.plugin)
        #expect(cfg.queryUrl.isEmpty)
        #expect(cfg.queryKey.isEmpty)
        #expect(cfg.refreshKey == "fixture-api-key")
        #expect(cfg.scheduleTimes == ["09:00"])
    }

    @Test func quotaAlwaysUsesTheBaseKeyAfterReplacementAndClear() throws {
        let f = try fixture(); defer { cleanup(f) }
        var row = try create(f, quota: true)
        #expect(try ProviderAuthentication.resolveQuota(f.model.readConfig(row.plugin)).queryKey == "fixture-api-key")
        f.model.startEdit()
        f.model.draft?.values.key = "replacement-base-key"
        f.model.save()
        row = try #require(f.model.current)
        var cfg = f.model.readConfig(row.plugin)
        #expect(cfg.refreshKey == "replacement-base-key")
        #expect(cfg.queryKey.isEmpty)
        #expect(try ProviderAuthentication.resolveQuota(cfg).queryKey == "replacement-base-key")
        #expect(cfg.queryUrl == "https://quota.example.test/account/usage")
        #expect(cfg.refreshUrl == "https://api.example.test/v1/chat/completions")
        #expect(f.model.quotaConfigured(row))
        #expect(!f.model.engine.triggerDisabledSlugs.contains(row.id))
        f.model.startEdit()
        f.model.draft?.values.clearKeyIntent = true
        f.model.draft?.values.key = ""
        f.model.save()
        row = try #require(f.model.current)
        cfg = f.model.readConfig(row.plugin)
        #expect(cfg.refreshKey.isEmpty)
        #expect(cfg.queryKey.isEmpty)
        #expect(f.model.engine.triggerDisabledSlugs.contains(row.id))
        #expect(!f.model.callConfigured(row))
        #expect(!f.model.quotaConfigured(row))
    }

    @Test func copyCreatesIndependentAccountWithoutSecretsOrActivePlan() throws {
        let f = try fixture(); defer { cleanup(f) }
        let first = try create(f, quota: true)
        f.model.duplicateAccount(first.id)
        let draft = try #require(f.model.draft)
        #expect(draft.isNew)
        #expect(draft.slug == nil)
        #expect(draft.values.key.isEmpty)
        #expect(!draft.values.autoTrigger)
        #expect(draft.values.times == ["09:00"])
        #expect(draft.values.queryURL == "https://quota.example.test/account/usage")
        #expect(f.model.engine.allPlugins.count == 1)
        f.model.draft?.values.key = "second-api-key"
        f.model.save()
        let second = try #require(f.model.current)
        #expect(second.id != first.id)
        #expect(second.plugin.manifest.authFile != first.plugin.manifest.authFile)
        #expect(DataEngine.cachePath(for: second.plugin, hudDir: f.hud)
                != DataEngine.cachePath(for: first.plugin, hudDir: f.hud))
        #expect(f.model.readConfig(first.plugin).refreshKey == "fixture-api-key")
        let secondConfig = f.model.readConfig(second.plugin)
        #expect(secondConfig.refreshKey == "second-api-key")
        #expect(secondConfig.queryKey.isEmpty)
        #expect(try ProviderAuthentication.resolveQuota(secondConfig).queryKey == "second-api-key")
        #expect(f.model.engine.triggerDisabledSlugs.contains(second.id))
    }

    @Test func fakeAuthDraftTestAndSaveShareSourceWithoutPersistingToken() async throws {
        let f = try fixture(withTemplate: true); defer { cleanup(f) }
        let token = "offline-auth-token-never-persist"
        let source = f.root.appendingPathComponent("fixture-auth.json")
        try JSONSerialization.data(withJSONObject: ["session": ["access_token": token]]).write(to: source)
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "fixture" }))
        f.model.draft?.values.name = "Auth fixture"
        f.model.draft?.values.authMode = "auth"
        f.model.draft?.values.key = ""
        let values = try #require(f.model.draft?.values)
        let draftConfig = f.model.callConfigForDraft(values)
        #expect(draftConfig.refreshKey.isEmpty)
        #expect(f.model.authSourceDescription(draftConfig) == source.path)
        #expect(f.model.authenticationIssue(draftConfig) == nil)
        f.model.testCallDraft(values: values)
        for _ in 0..<100 where f.model.isTestingCurrentConfig { await Task.yield() }
        #expect(f.model.callTestResult(for: nil)?.phase == .success)
        #expect(f.model.callTestResult(for: nil)?.target == "https://auth.example.test/v1/responses")
        f.model.save()
        let row = try #require(f.model.current)
        #expect(f.model.callConfigured(row))
        #expect(f.model.quotaConfigured(row))
        let saved = f.model.readConfig(row.plugin)
        #expect(saved.authMode == "auth")
        #expect(saved.refreshKey.isEmpty)
        let contents = try String(contentsOf: try #require(f.model.authURL(row.plugin)), encoding: .utf8)
        #expect(!contents.contains(token))
        f.model.startEdit()
        #expect(f.model.draft?.values.authMode == "auth")
        #expect(f.model.draft?.values.key.isEmpty == true)
    }

    @Test func newBuiltinAccountKeepsQuotaDisabled() throws {
        let f = try fixture(withTemplate: true); defer { cleanup(f) }
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "fixture" }))
        f.model.draft?.values.name = "Builtin with quota off"
        f.model.draft?.values.key = "offline-key"
        f.model.draft?.values.quotaMode = "none"
        f.model.save()
        #expect(f.model.topError.isEmpty)
        let row = try #require(f.model.current)
        #expect(f.model.readConfig(row.plugin).quotaMode == "none")
        #expect(!f.model.quotaConfigured(row))
        #expect(f.model.callConfigured(row))
    }

    @Test func clearingBaseKeyInvalidatesQuotaAuthentication() throws {
        let f = try fixture(); defer { cleanup(f) }
        var row = try create(f, quota: true)
        let auth = try #require(f.model.authURL(row.plugin))
        var obsolete = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        obsolete["quotaCredentialMode"] = "legacy"
        obsolete["queryKey"] = "obsolete-query-key"
        obsolete["queryToken"] = "obsolete-query-token"
        obsolete["queryCookie"] = "obsolete-query-cookie"
        try JSONSerialization.data(withJSONObject: obsolete).write(to: auth)
        #expect(f.model.quotaConfigured(row))
        f.model.startEdit()
        f.model.draft?.values.clearKeyIntent = true
        f.model.draft?.values.key = ""
        f.model.save()
        row = try #require(f.model.current)
        let config = f.model.readConfig(row.plugin)
        #expect(config.queryKey.isEmpty)
        #expect(!f.model.quotaConfigured(row))
        #expect(!f.model.callConfigured(row))
    }

    @Test func authSelectionPersistsWithoutUsingAnExistingAPIKeyAsAuthorization() throws {
        let f = try fixture(); defer { cleanup(f) }
        _ = try create(f)
        f.model.startEdit()
        f.model.draft?.values.authMode = "auth"
        f.model.draft?.values.authCredentialFile = f.root.appendingPathComponent("missing-auth.json").path
        let values = try #require(f.model.draft?.values)
        let snapshot = f.model.callConfigForDraft(values)
        #expect(snapshot.authMode == "auth")
        #expect(f.model.authenticationIssue(snapshot) != nil)
        f.model.testCallDraft(values: values)
        #expect(f.model.callTestResult(for: nil)?.phase == .failure)
        f.model.save()
        let row = try #require(f.model.current)
        let saved = f.model.readConfig(row.plugin)
        #expect(saved.authMode == "auth")
        #expect(saved.authCredentialFile == values.authCredentialFile)
        #expect(!f.model.callConfigured(row))
        f.model.startEdit()
        #expect(f.model.draft?.values.authMode == "auth")
    }

    @Test func unchangedSaveDropsObsoleteQueryCacheAndPreservesBaseAuthentication() throws {
        let f = try fixture(withTemplate: true); defer { cleanup(f) }
        let source = f.root.appendingPathComponent("fixture-auth.json")
        let authorization = try JSONSerialization.data(withJSONObject: ["session": ["access_token": "offline-source-token"]])
        try authorization.write(to: source)
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "fixture" }))
        f.model.draft?.values.name = "Migrated account"
        f.model.draft?.values.key = "preserved-base-key"
        f.model.draft?.values.authCredentialFile = source.path
        f.model.save()
        let first = try #require(f.model.current)
        let other = try create(f, quota: true)
        let auth = try #require(f.model.authURL(first.plugin))
        let otherAuth = try #require(f.model.authURL(other.plugin))
        let otherConfig = try Data(contentsOf: otherAuth)
        var obsolete = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        obsolete["quotaCredentialMode"] = "legacy"
        obsolete["queryKey"] = "obsolete-query-key"
        try JSONSerialization.data(withJSONObject: obsolete).write(to: auth)
        let firstCache = DataEngine.cachePath(for: first.plugin, hudDir: f.hud)
        let otherCache = DataEngine.cachePath(for: other.plugin, hudDir: f.hud)
        let cached = try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000,
                                                         fiveHour: Bucket(usedPercentage: 35)))
        try cached.write(to: firstCache)
        try cached.write(to: otherCache)
        f.model.engine.reloadRegistry()
        f.model.lastSuccess[first.id] = Date()
        #expect(f.model.selectAccount(first.id, tab: .config))
        f.model.startEdit()
        #expect(f.model.draft?.dirty == false)
        f.model.save()
        #expect(f.model.topError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: firstCache.path))
        #expect(f.model.row(first.id)?.state?.cache == nil)
        #expect(f.model.lastSuccess[first.id] == nil)
        #expect(try Data(contentsOf: otherCache) == cached)
        #expect(try Data(contentsOf: otherAuth) == otherConfig)
        #expect(try Data(contentsOf: source) == authorization)
        let saved = f.model.readConfig(try #require(f.model.current?.plugin))
        #expect(saved.refreshKey == "preserved-base-key")
        #expect(saved.authMode == "apikey")
        #expect(saved.authCredentialFile == source.path)
        #expect(!ProviderConfigStore.hasObsoleteQueryCredentials(authFile: auth, manifest: first.plugin.manifest))
    }

    @Test func authenticationChangesClearOnlyThatAccountsQuotaCache() throws {
        let f = try fixture(withTemplate: true); defer { cleanup(f) }
        let authorization = try JSONSerialization.data(withJSONObject: ["session": ["access_token": "offline-cache-auth"]])
        try authorization.write(to: f.root.appendingPathComponent("fixture-auth.json"))
        try authorization.write(to: f.root.appendingPathComponent("another-auth.json"))
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "fixture" }))
        f.model.draft?.values.name = "First cache identity"
        f.model.draft?.values.key = "initial-base-key"
        f.model.save()
        let first = try #require(f.model.current)
        let other = try create(f, quota: true)
        let firstCache = DataEngine.cachePath(for: first.plugin, hudDir: f.hud)
        let otherCache = DataEngine.cachePath(for: other.plugin, hudDir: f.hud)
        let cached = try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000,
                                                        fiveHour: Bucket(usedPercentage: 35)))
        try cached.write(to: otherCache)
        #expect(f.model.selectAccount(first.id, tab: .config))
        f.model.startEdit()
        f.model.save()
        let changes: [(WritableKeyPath<DraftValues, String>, String)] = [
            (\.key, "new-base-key"), (\.authCredentialFile, f.root.appendingPathComponent("another-auth.json").path),
            (\.authMode, "auth"), (\.queryURL, "https://quota.example.test/changed"),
            (\.quotaMode, "none")
        ]
        for (field, value) in changes {
            let currentCache = try JSONEncoder().encode(UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000,
                                                                  fiveHour: Bucket(usedPercentage: 35)))
            try currentCache.write(to: firstCache)
            f.model.engine.reloadRegistry()
            #expect(f.model.row(first.id)?.state?.cache != nil)
            f.model.lastSuccess[first.id] = Date()
            f.model.startEdit()
            f.model.draft?.values[keyPath: field] = value
            f.model.save()
            #expect(f.model.topError.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: firstCache.path))
            #expect(f.model.row(first.id)?.state?.cache == nil)
            #expect(f.model.lastSuccess[first.id] == nil)
            #expect(try Data(contentsOf: otherCache) == cached)
            #expect(f.model.readConfig(try #require(f.model.current?.plugin)).queryKey.isEmpty)
        }
    }

    @Test func disabledAuthAccountRejectsCacheAfterSourceChangesOrDisappears() throws {
        let f = try fixture(withTemplate: true); defer { cleanup(f) }
        let source = f.root.appendingPathComponent("fixture-auth.json")
        let baseline = Date().addingTimeInterval(-60)
        try JSONSerialization.data(withJSONObject: ["session": ["access_token": "offline-account-a"]]).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(-2)], ofItemAtPath: source.path)
        f.model.pickTemplate(try #require(f.model.choices.first { $0.id == "fixture" }))
        f.model.draft?.values.name = "Disabled Auth cache"
        f.model.draft?.values.authMode = "auth"
        f.model.save()
        let row = try #require(f.model.current)
        let cache = DataEngine.cachePath(for: row.plugin, hudDir: f.hud)
        let original = try JSONEncoder().encode(UsageCache(generatedAt: baseline.timeIntervalSince1970 * 1000,
                                                          fiveHour: Bucket(usedPercentage: 35)))
        try original.write(to: cache)
        f.model.engine.setTracking(row.id, enabled: false)
        #expect(!f.model.engine.states.contains { $0.slug == row.id })
        #expect(f.model.row(row.id)?.state?.cache?.fiveHour?.usedPercentage == 35)
        try JSONSerialization.data(withJSONObject: ["session": ["access_token": "offline-account-b"]]).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(2)], ofItemAtPath: source.path)
        #expect(f.model.row(row.id)?.state?.cache == nil)
        #expect(try Data(contentsOf: cache) == original)
        let updated = try JSONEncoder().encode(UsageCache(generatedAt: baseline.addingTimeInterval(4).timeIntervalSince1970 * 1000,
                                                         fiveHour: Bucket(usedPercentage: 18)))
        try updated.write(to: cache)
        #expect(f.model.row(row.id)?.state?.cache?.fiveHour?.usedPercentage == 18)
        try FileManager.default.removeItem(at: source)
        #expect(f.model.row(row.id)?.state?.cache == nil)
        #expect(try Data(contentsOf: cache) == updated)
    }

    @Test func savedTestSuccessQueriesQuotaButQueryFailureDoesNotChangeCallSuccess() async throws {
        var queried: [String] = []
        let f = try fixture(query: { slug in queried.append(slug); return .failed("offline query failure") })
        defer { cleanup(f) }
        let row = try create(f, quota: true)
        f.model.testCall(row.id)
        for _ in 0..<100 where f.model.callRunning.contains(row.id) || queried.isEmpty || f.model.running.contains(row.id) {
            await Task.yield()
        }
        #expect(queried == [row.id])
        #expect(f.model.callTestResult(for: row.id)?.phase == .success)
        #expect(f.model.lastRun[row.id]?.ok == false)
        #expect(f.model.toast?.text.contains("查询失败") == true)
        #expect(f.model.toast?.text.contains("开窗") == false)
    }

    @Test func draftSuccessDoesNotQuerySavedAccount() async throws {
        var queries = 0
        let f = try fixture(query: { _ in queries += 1; return .ok })
        defer { cleanup(f) }
        let row = try create(f, quota: true)
        f.model.startEdit()
        f.model.draft?.values.key = "draft-only-key"
        f.model.testCallDraft(values: try #require(f.model.draft?.values))
        for _ in 0..<100 where f.model.isTestingCurrentConfig { await Task.yield() }
        #expect(f.model.callTestResult(for: row.id)?.phase == .success)
        #expect(queries == 0)
    }

    @Test func savedTestSkipsQuotaWhenCurrentBaseAuthenticationChanged() async throws {
        var release = false
        var queries = 0
        let f = try fixture(execute: { _ in
            while !release { await Task.yield() }
            return "✓ offline"
        }, query: { _ in queries += 1; return .ok })
        defer { cleanup(f) }
        let row = try create(f, quota: true)
        f.model.testCall(row.id)
        var changed = f.model.readConfig(row.plugin)
        changed.refreshKey = "rotated-during-call"
        try ProviderConfigStore.write(changed, manifest: row.plugin.manifest, to: try #require(f.model.authURL(row.plugin)))
        release = true
        for _ in 0..<100 where f.model.callRunning.contains(row.id) { await Task.yield() }
        #expect(f.model.callTestResult(for: row.id)?.phase == .success)
        #expect(queries == 0)
    }

    @Test func discardedDraftIsNotResurrected() throws {
        let f = try fixture(); defer { cleanup(f) }
        _ = try create(f)
        f.model.startEdit()
        f.model.draft?.values.name = "unsaved rename"
        #expect(f.model.draft?.dirty == true)
        f.model.discardDraft()
        #expect(f.model.draft == nil)
        f.model.startEdit()
        #expect(f.model.draft?.values.name == "Work subscription")
    }

    @Test func absentAuthStillUsesFixedTypeEndpointsAndModel() throws {
        let m = ProviderManifest(name: "Fixed", label: "Fixed", testModel: "fixed-model",
                                 refreshUrl: "https://type.example.test/v1/messages",
                                 refreshProtocol: "anthropic", quotaMode: "script")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let c = ProviderConfigStore.read(authFile: missing, manifest: m)
        #expect(c.refreshUrl == "https://type.example.test/v1/messages")
        #expect(c.refreshProtocol == "anthropic")
        #expect(c.testModel == "fixed-model")
        #expect(c.refreshKey.isEmpty)
    }

    @Test func explicitEmptyAPIKeyNeverFallsBackToQuotaKey() throws {
        let f = try fixture(); defer { cleanup(f) }
        var cfg = ProviderConfig()
        cfg.refreshKey = ""
        cfg.queryKey = "quota-only"
        cfg.quotaMode = "endpoint"
        let auth = f.hud.appendingPathComponent(".independent-usage-auth.json")
        let m = ProviderManifest(name: "Independent", label: "Independent", queryAuth: "bearer")
        try ProviderConfigStore.write(cfg, manifest: m, to: auth)
        let read = ProviderConfigStore.read(authFile: auth, manifest: m)
        #expect(read.queryKey.isEmpty)
        #expect(throws: (any Error).self) { try ProviderAuthentication.resolveQuota(read) }
        #expect(read.refreshKey.isEmpty)
    }

    @Test func legacyEmptyCallKeyAndV2ExplicitClearHaveDifferentMeaning() throws {
        let f = try fixture(); defer { cleanup(f) }
        let auth = f.hud.appendingPathComponent(".legacy-usage-auth.json")
        let manifest = ProviderManifest(name: "Legacy", label: "Legacy", queryAuth: "bearer")
        try Data(#"{"schemaVersion":1,"refreshApiKey":"","headers":{"Authorization":"Bearer legacy-shared-key"}}"#.utf8).write(to: auth)
        #expect(ProviderConfigStore.read(authFile: auth, manifest: manifest).refreshKey == "legacy-shared-key")
        try Data(#"{"schemaVersion":2,"refreshApiKey":"","queryKey":"query-only"}"#.utf8).write(to: auth)
        let cleared = ProviderConfigStore.read(authFile: auth, manifest: manifest)
        #expect(cleared.refreshKey.isEmpty)
        #expect(cleared.queryKey.isEmpty)
    }

    @Test func planRowsShowPersistedTerminalOutcomes() throws {
        let f = try fixture(); defer { cleanup(f) }
        let row = try create(f)
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let key = "\(date.string(from: Date()))|\(row.id)"
        for (outcome, expected) in [("succeeded", "调用成功"), ("failed", "调用失败"),
                                    ("uncertain", "结果不确定"), ("skipped:disabled", "已停用")] {
            let data = try JSONEncoder().encode([key: ["09:00": outcome]])
            f.defaults.set(String(decoding: data, as: UTF8.self), forKey: DataEngine.defaultsScheduleFiredKey)
            #expect(f.model.planRows.first?.lastOutcome?.contains(expected) == true)
        }
    }

    @Test func endpointResolutionPreservesAlreadyCompletePaths() {
        #expect(APIEndpoint.requestURL(baseURL: "https://a.test/v1/messages", protocolName: "anthropic")
                == "https://a.test/v1/messages")
        #expect(APIEndpoint.requestURL(baseURL: "https://a.test/v1/chat/completions/", protocolName: "openai")
                == "https://a.test/v1/chat/completions")
        #expect(APIEndpoint.requestURL(baseURL: "", protocolName: "openai").isEmpty)
    }
}
