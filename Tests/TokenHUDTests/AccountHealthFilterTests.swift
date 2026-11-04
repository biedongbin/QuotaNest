import Foundation
import Testing
@testable import TokenHUD

struct AccountHealthAssessmentTests {
    private var manifest: ProviderManifest {
        ProviderManifest(name: "offline", label: "Offline", queryUrl: "https://example.test/quota", quotaMode: "endpoint")
    }
    private var config: ProviderConfig {
        var config = ProviderConfig()
        config.refreshKey = "offline-placeholder"
        config.queryUrl = "https://example.test/quota"
        config.quotaMode = "endpoint"
        return config
    }
    private func result(_ phase: CallTestResult.Phase, _ message: String, at time: Double) -> CallTestResult {
        CallTestResult(phase: phase, model: "offline", target: "example.test", sourceLabel: "测试",
                       message: message, date: Date(timeIntervalSince1970: time))
    }

    @Test func completeQuotaAccountWithoutCallsOrHistoryIsHealthy() {
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: config) == .healthy)
        #expect(AccountHealthAssessment.assess(configuration: .healthy, cache: nil, callResult: nil) == .healthy)
        var callOnly = config
        callOnly.quotaMode = "none"
        callOnly.apiBaseURL = "https://example.test"
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: callOnly) == .healthy)
    }

    @Test func missingKeyAddressAndUnsupportedQueryAreIssues() {
        var c = config
        c.refreshKey = ""
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c = config
        c.queryUrl = "not a URL"
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c.queryUrl = ""
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c = config
        c.quotaMode = "unknown"
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c = config
        c.quotaMode = "none"
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c.apiBaseURL = "https://example.test"
        c.scheduleTimes = ["09:00"]
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c, scheduleEnabled: true).isHealthy)
    }

    @Test func authReadinessUsesDeclaredFileAndDoesNotRequireCallAdapter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.json")
        var c = config
        c.authMode = "auth"
        c.credentialSource = ProviderCredentialSource(file: source.path, tokenPath: "access_token")
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        try Data(#"{"access_token":"opaque-offline-token","expires_at":1}"#.utf8).write(to: source)
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: c) == .healthy)
        c.quotaMode = "none"
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: c) == .healthy)
        c.authCredentialFile = root.appendingPathComponent("missing.json").path
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
        c.authCredentialFile = source.path
        try Data(#"{"different_field":"missing supported token"}"#.utf8).write(to: source)
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
    }

    @Test func scriptAdapterMayDeriveURLFromDeclaredAuthContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("auth.json")
        try Data(#"{"deviceToken":"offline-token","enterpriseHost":"https://example.test"}"#.utf8).write(to: source)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf:
            repository.appendingPathComponent("Sources/TokenHUD/providers/qwenwork-enterprise/manifest.json")))
        var c = ProviderConfigStore.applyingManifest(manifest, to: ProviderConfig())
        c.authMode = "auth"
        c.authCredentialFile = source.path
        c.quotaMode = "script"
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: c) == .healthy)
        c.queryUrl = "invalid URL"
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: c).isHealthy)
    }

    @Test func onlyNumericJWTExpiryCounts() throws {
        func jwt(_ payload: [String: Any]) throws -> String {
            let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            return "header.\(encoded).signature"
        }
        let now = Date(timeIntervalSince1970: 100)
        #expect(AccountHealthAssessment.jwtExpired(try jwt(["exp": 99]), now: now))
        #expect(!AccountHealthAssessment.jwtExpired(try jwt(["exp": 101]), now: now))
        #expect(!AccountHealthAssessment.jwtExpired(try jwt(["exp": "99"]), now: now))
        #expect(!AccountHealthAssessment.jwtExpired(try jwt(["exp": false]), now: now))
        #expect(!AccountHealthAssessment.jwtExpired("not-a-jwt", now: now))
    }

    @Test(arguments: ["auth", "no-auth", "expired", "authfail", "HTTP 401", "HTTP 400 invalid model", "HTTP 404 endpoint not found", "HTTP 403 permission denied"])
    func explicitPersistentEvidenceIsAbnormal(_ error: String) {
        #expect(!AccountHealthAssessment.assess(configuration: .healthy,
            cache: UsageCache(error: error, lastAttemptAt: 2000), callResult: nil).isHealthy)
        #expect(!AccountHealthAssessment.assess(configuration: .healthy, cache: nil,
            callResult: result(.failure, error, at: 2)).isHealthy)
    }

    @Test(arguments: ["network", "timeout", "DNS lookup failed", "HTTP 500", "HTTP 503", "HTTP 429", "no-query", "parse", "temporary busy", "HTTP 400", "HTTP 403", "HTTP 403 intermediary rejected", "HTTP 500 invalid api key"])
    func transientAndAmbiguousEvidenceDoesNotDamageAccount(_ error: String) {
        #expect(AccountHealthAssessment.assess(configuration: .healthy,
            cache: UsageCache(error: error, lastAttemptAt: 2000), callResult: result(.failure, error, at: 2)) == .healthy)
        #expect(AccountHealthAssessment.assess(configuration: .healthy, cache: nil,
            callResult: result(.uncertain, "HTTP 401", at: 2)) == .healthy)
    }

    @Test func outerHTTPStatusOutranksBodyKeywords() {
        #expect(AccountHealthAssessment.persistentIssue(#"HTTP 401: {"error":"invalid_api_key","message":"connection authentication failed"}"#) != nil)
        #expect(AccountHealthAssessment.persistentIssue("HTTP 401: malformed body; network parse failure") != nil)
        #expect(AccountHealthAssessment.persistentIssue(#"HTTP 500: {"error":"invalid_api_key","message":"authentication failed"}"#) == nil)
        #expect(AccountHealthAssessment.persistentIssue("HTTP 429: authentication failed") == nil)
        #expect(AccountHealthAssessment.persistentIssue("network timeout while checking HTTP 401") == nil)
        #expect(AccountHealthAssessment.persistentIssue("upstream diagnostic mentions HTTP 401") == nil)
    }

    @Test func successRecoversOnlyItsOwnEvidenceChannel() {
        let failure = UsageCache(generatedAt: 1000, error: "auth", lastAttemptAt: 3000)
        #expect(!AccountHealthAssessment.assess(configuration: .healthy, cache: failure,
            callResult: result(.success, "OK", at: 4)).isHealthy)
        #expect(!AccountHealthAssessment.assess(configuration: .healthy,
            cache: UsageCache(generatedAt: 4000), callResult: result(.failure, "HTTP 400 invalid model", at: 3)).isHealthy)
        #expect(AccountHealthAssessment.assess(configuration: .healthy,
            cache: UsageCache(generatedAt: 4000, error: "timeout", lastAttemptAt: 5000),
            callResult: result(.success, "OK", at: 3)) == .healthy)
        #expect(AccountHealthAssessment.assess(configuration: .healthy, cache: failure,
            callResult: nil, lastSuccess: Date(timeIntervalSince1970: 4)) == .healthy)
        #expect(AccountHealthAssessment.assess(configuration: .healthy, cache: UsageCache(generatedAt: 4000),
            callResult: result(.success, "OK", at: 4)) == .healthy)
        #expect(AccountHealthAssessment.assess(configuration: .issue(reason: "缺少配置"),
            cache: UsageCache(generatedAt: 4000), callResult: result(.success, "OK", at: 4)) == .issue(reason: "缺少配置"))
    }
}

@Suite(.serialized)
@MainActor
struct AccountStatusFilterTests {
    private func withModel(_ body: (SettingsModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-filters-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        let suite = "health-filters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        for (slug, label, name, key) in [("alpha", "Provider A", "First", "fixture"),
                                        ("beta", "Provider B", "Second", "fixture"),
                                        ("gamma", "Provider A", "Third", ""),
                                        ("delta", "Provider A", "Fourth", "fixture")] {
            let auth = hud.appendingPathComponent(".\(slug)-usage-auth.json")
            var manifest = ProviderManifest(name: slug, label: label, authFile: auth.path,
                refreshUrl: "https://example.test/v1/chat/completions", authMode: "apikey")
            manifest.displayName = name
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "", into: providers)
            var config = ProviderConfig()
            config.refreshKey = key
            config.testModel = "offline-model"
            config.apiBaseURL = "https://example.test"
            config.refreshUrl = "https://example.test/v1/chat/completions"
            try ProviderConfigStore.write(config, manifest: manifest, to: auth)
        }
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: root), defaults: defaults,
            settingsURL: root.appendingPathComponent("settings.json"))
        engine.reloadRegistry()
        engine.setTracking("beta", enabled: false)
        engine.setTracking("gamma", enabled: false)
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
            settingsURL: root.appendingPathComponent("settings.json"), bundleDir: nil, defaults: defaults,
            confirmTestCall: { _ in true }, executeTestCall: { config in
                config.refreshKey == "draft-success" ? "✓ offline success" : "HTTP 401"
            })
        try await body(model)
    }

    @Test func defaultsAndIndependentEnablementHealthDimensions() async throws {
        try await withModel { model in
            #expect(model.overviewStatusFilter == .all)
            #expect(model.sidebarStatusFilter == .healthyEnabled)
            #expect(Set(model.sidebarGroups.flatMap(\.rows).map(\.id)) == ["alpha", "delta"])
            #expect(model.overviewGroups.flatMap(\.rows).count == 4)
            model.overviewStatusFilter = .abnormal
            #expect(model.overviewGroups.flatMap(\.rows).map(\.id) == ["gamma"])
            #expect(model.row("gamma")?.enabled == false)
            #expect(model.row("gamma")?.status.1 == "已停用")
            #expect(Set(model.sidebarGroups.flatMap(\.rows).map(\.id)) == ["alpha", "delta"])
            model.sidebarStatusFilter = .disabled
            #expect(Set(model.sidebarGroups.flatMap(\.rows).map(\.id)) == ["beta", "gamma"])
            #expect(model.overviewGroups.flatMap(\.rows).map(\.id) == ["gamma"])
            model.overviewStatusFilter = .enabled
            #expect(Set(model.overviewGroups.flatMap(\.rows).map(\.id)) == ["alpha", "delta"])
        }
    }

    @Test func draftTestResultsCannotChangeSavedAccountHealth() async throws {
        try await withModel { model in
            #expect(model.selectAccount("alpha", tab: .config))
            model.startEdit()
            var values = try #require(model.draft?.values)
            values.key = "draft-invalid"
            model.testCallDraft(values: values)
            for _ in 0..<200 where model.isTestingCurrentConfig { await Task.yield() }
            #expect(model.callTestResult(for: "alpha")?.phase == .failure)
            #expect(model.row("alpha")?.health == .healthy)
            model.discardDraft()
            #expect(model.row("alpha")?.health == .healthy)
            model.testCall("alpha")
            for _ in 0..<200 where model.callRunning.contains("alpha") { await Task.yield() }
            #expect(model.row("alpha")?.health.isHealthy == false)
            model.startEdit()
            values = try #require(model.draft?.values)
            values.key = "draft-success"
            model.testCallDraft(values: values)
            for _ in 0..<200 where model.isTestingCurrentConfig { await Task.yield() }
            #expect(model.callTestResult(for: "alpha")?.phase == .success)
            #expect(model.row("alpha")?.health.isHealthy == false)
            model.discardDraft()
            #expect(model.row("alpha")?.health.isHealthy == false)
        }
    }

    @Test func sharedGroupingRetainsSearchOrderAndScopeWithoutChangingDraftOrTracking() async throws {
        try await withModel { model in
            model.sidebarStatusFilter = .all
            let original = model.overviewGroups
            #expect(original.map(\.label) == model.sidebarGroups.map(\.label))
            #expect(original.map { $0.rows.map(\.id) } == model.sidebarGroups.map { $0.rows.map(\.id) })
            #expect(original.first { $0.label == "Provider A" }?.rows.count == 3)
            let enabledBefore = model.allAccounts.map(\.enabled)
            #expect(model.selectAccount("alpha", tab: .config))
            model.startEdit()
            model.draft?.values.name = "未保存"
            model.search = "Provider A"
            #expect(model.sidebarGroups.count == 1)
            #expect(model.sidebarGroups.first?.rows.map(\.id) == original.first { $0.label == "Provider A" }?.rows.map(\.id))
            model.scope = .disabled
            #expect(model.overviewGroups.flatMap(\.rows).map(\.id) == ["gamma"])
            #expect(model.sidebarGroups.flatMap(\.rows).count == 3)
            model.search = "Fourth"
            #expect(model.sidebarGroups.flatMap(\.rows).map(\.id) == ["delta"])
            model.sidebarStatusFilter = .abnormal
            #expect(model.sidebarGroups.isEmpty)
            #expect(model.selected == "alpha")
            #expect(model.draft?.values.name == "未保存")
            #expect(model.draft?.dirty == true)
            #expect(model.allAccounts.map(\.enabled) == enabledBefore)
        }
    }
}
