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

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-accounts-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let suite = "tokenhud.accounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                                settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: nil, defaults: defaults, confirmDiscardChanges: { true },
                                  confirmResumePlan: { true }, confirmTestCall: { _ in true },
                                  executeTestCall: { _ in "✓ offline" })
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
            f.model.draft?.values.queryKey = "fixture-quota-key"
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

    @Test func separateCredentialsSurviveSaveAndIndependentClear() throws {
        let f = try fixture(); defer { cleanup(f) }
        var row = try create(f, quota: true)
        f.model.startEdit()
        f.model.draft?.values.queryKey = "replacement-query-key"
        f.model.save()
        row = try #require(f.model.current)
        var cfg = f.model.readConfig(row.plugin)
        #expect(cfg.refreshKey == "fixture-api-key")
        #expect(cfg.queryKey == "replacement-query-key")
        #expect(cfg.queryUrl == "https://quota.example.test/account/usage")
        #expect(cfg.refreshUrl == "https://api.example.test/v1/chat/completions")
        f.model.startEdit()
        f.model.draft?.values.clearQueryKeyIntent = true
        f.model.save()
        row = try #require(f.model.current)
        cfg = f.model.readConfig(row.plugin)
        #expect(cfg.queryKey.isEmpty)
        #expect(cfg.refreshKey == "fixture-api-key")
        #expect(!f.model.engine.triggerDisabledSlugs.contains(row.id))
        f.model.startEdit()
        f.model.draft?.values.clearKeyIntent = true
        f.model.draft?.values.key = ""
        f.model.save()
        row = try #require(f.model.current)
        cfg = f.model.readConfig(row.plugin)
        #expect(cfg.refreshKey.isEmpty)
        #expect(f.model.engine.triggerDisabledSlugs.contains(row.id))
        #expect(!f.model.callConfigured(row))
    }

    @Test func copyCreatesIndependentAccountWithoutSecretsOrActivePlan() throws {
        let f = try fixture(); defer { cleanup(f) }
        let first = try create(f, quota: true)
        f.model.duplicateAccount(first.id)
        let draft = try #require(f.model.draft)
        #expect(draft.isNew)
        #expect(draft.slug == nil)
        #expect(draft.values.key.isEmpty)
        #expect(draft.values.queryKey.isEmpty)
        #expect(draft.values.queryToken.isEmpty)
        #expect(draft.values.queryCookie.isEmpty)
        #expect(!draft.values.autoTrigger)
        #expect(draft.values.times == ["09:00"])
        #expect(draft.values.queryURL == "https://quota.example.test/account/usage")
        #expect(f.model.engine.allPlugins.count == 1)
        f.model.draft?.values.key = "second-api-key"
        f.model.draft?.values.queryKey = "second-quota-key"
        f.model.save()
        let second = try #require(f.model.current)
        #expect(second.id != first.id)
        #expect(second.plugin.manifest.authFile != first.plugin.manifest.authFile)
        #expect(DataEngine.cachePath(for: second.plugin, hudDir: f.hud)
                != DataEngine.cachePath(for: first.plugin, hudDir: f.hud))
        #expect(f.model.readConfig(first.plugin).refreshKey == "fixture-api-key")
        #expect(f.model.engine.triggerDisabledSlugs.contains(second.id))
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
        #expect(read.queryKey == "quota-only")
        #expect(read.refreshKey.isEmpty)
    }

    @Test func legacyEmptyCallKeyAndV2ExplicitClearHaveDifferentMeaning() throws {
        let f = try fixture(); defer { cleanup(f) }
        let auth = f.hud.appendingPathComponent(".legacy-usage-auth.json")
        let manifest = ProviderManifest(name: "Legacy", label: "Legacy", queryAuth: "bearer")
        try Data(#"{"schemaVersion":1,"refreshApiKey":"","headers":{"Authorization":"Bearer legacy-shared-key"}}"#.utf8).write(to: auth)
        #expect(ProviderConfigStore.read(authFile: auth, manifest: manifest).refreshKey == "legacy-shared-key")
        try Data(#"{"schemaVersion":2,"refreshApiKey":"","queryKey":"query-only"}"#.utf8).write(to: auth)
        #expect(ProviderConfigStore.read(authFile: auth, manifest: manifest).refreshKey.isEmpty)
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
