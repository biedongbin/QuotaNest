import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized) @MainActor
struct WindowCallTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let auth: URL
        let manifest: ProviderManifest
        let model: SettingsModel
        let defaults: UserDefaults
        let suite: String
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func fixture(window: Bool = true, execute: @escaping (ProviderConfig) async -> String?) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-call-\(UUID())")
        let hud = root.appendingPathComponent("hud"), providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.json")
        try #"{"type":"clinepass","api_key":"fixture-key","base_url":"https://fixture.invalid/v1","model":"source-model"}"#
            .write(to: source, atomically: true, encoding: .utf8)
        let auth = hud.appendingPathComponent(".sample-usage-auth.json")
        let manifest = ProviderManifest(name: "Fixture", label: "Fixture", authFile: auth.path,
            refreshUrl: "https://fixture.invalid/v1/chat/completions", refreshProtocol: "openai", quotaMode: "none",
            sourceReference: ProviderSourceReference(source: "cpamp", path: source.path, recordId: "source.json", providerId: "clinepass"),
            testMaxTokens: 1024,
            windowTrigger: window ? ProviderWindowTrigger(period: "five_hour", model: "plan-model") : nil)
        try PluginGenerator.writePlugin(slug: "sample", manifest: manifest, script: "exit 1", into: providers)
        try ProviderConfigStore.write(ProviderConfig(), manifest: manifest, to: auth)
        let settings = root.appendingPathComponent("settings.json")
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        let suite = "window-call.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: isolated, settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
            bundleDir: nil, defaults: isolated, confirmDiscardChanges: { true }, executeTestCall: execute)
        return Fixture(root: root, source: source, auth: auth, manifest: manifest, model: model, defaults: isolated, suite: suite)
    }
    private func waitForCall(_ model: SettingsModel) async throws {
        for _ in 0..<100 where !model.callRunning.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
    }
    private func body(_ config: ProviderConfig) throws -> [String: Any] {
        let request = try RefreshTrigger.callRequest(config: config)
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func selectedModelMatchesConfirmationAndFinalRequestBody() async throws {
        var sent: [ProviderConfig] = []
        let f = try fixture { sent.append($0); return "✓ fixture" }; defer { f.cleanup() }
        f.model.testCall("sample", modelOverride: "deepseek/deepseek-v4.1-flash-1017")
        #expect(f.model.pendingTestConfirmation?.model == "deepseek/deepseek-v4.1-flash-1017")
        #expect(sent.isEmpty)
        f.model.confirmPendingTestCall()
        try await waitForCall(f.model)
        let snapshot = try #require(sent.first)
        let request = try body(snapshot)
        #expect(request["model"] as? String == "deepseek/deepseek-v4.1-flash-1017")
        #expect(request["max_tokens"] as? Int == 1024)
        #expect(f.model.callTestResult(for: "sample")?.model == request["model"] as? String)
    }

    @Test func savedLocalModelSurvivesSourceChangeWithoutCopyingCredentials() throws {
        let f = try fixture { _ in "✓ fixture" }; defer { f.cleanup() }
        let before = try Data(contentsOf: f.source)
        #expect(f.model.saveCallModel("sample", model: "deepseek/selected"))
        #expect(try Data(contentsOf: f.source) == before)
        var config = ProviderConfigStore.read(authFile: f.auth, manifest: f.manifest)
        #expect(try ProviderAuthentication.resolveCall(config).testModel == "deepseek/selected")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.auth)) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "sourceReference", "callModelOverride"])
        #expect(!String(decoding: try Data(contentsOf: f.auth), as: UTF8.self).contains("fixture-key"))
        try #"{"type":"clinepass","api_key":"rotated-key","base_url":"https://fixture.invalid/v1","model":"new-source-model"}"#
            .write(to: f.source, atomically: true, encoding: .utf8)
        config = ProviderConfigStore.read(authFile: f.auth, manifest: f.manifest)
        #expect(try ProviderAuthentication.resolveCall(config).testModel == "deepseek/selected")
        #expect(try ProviderAuthentication.resolveCall(config).refreshKey == "rotated-key")
        #expect(!f.model.saveCallModel("sample", model: "   "))
    }

    @Test func windowClickUsesPlanModelOnceWithoutNavigationOrConfirmation() async throws {
        var sent: [ProviderConfig] = []
        let f = try fixture { sent.append($0); return "HTTP 500: empty response content" }; defer { f.cleanup() }
        #expect(f.model.saveCallModel("sample", model: "unrelated-validation-model"))
        let page = f.model.navPage, selected = f.model.selected
        f.model.triggerWindow("sample")
        f.model.triggerWindow("sample")
        #expect(f.model.pendingTestConfirmation == nil)
        #expect(f.model.navPage == page && f.model.selected == selected)
        try await waitForCall(f.model)
        #expect(sent.count == 1)
        #expect(try body(#require(sent.first))["model"] as? String == "plan-model")
        #expect(f.model.windowCallResult(for: "sample")?.phase == .failure)
        #expect(f.model.windowCallResult(for: "sample")?.sourceLabel == "5h 窗口调用")
        #expect(f.model.callTestResult(for: "sample") == nil)
        #expect(ProviderConfigStore.read(authFile: f.auth, manifest: f.manifest).callModelOverride == "unrelated-validation-model")
    }

    @Test func importedAccountPlanIsLocalAndControlsWindowCalls() async throws {
        var sent: [ProviderConfig] = []
        let f = try fixture { sent.append($0); return "✓ fixture" }; defer { f.cleanup() }
        let source = try Data(contentsOf: f.source)
        #expect(f.model.saveCallSchedule("sample", times: ["15:00"], timeInput: "09:00", model: "chosen-plan-model", enabled: true))
        var saved = ProviderConfigStore.read(authFile: f.auth, manifest: f.manifest)
        #expect(saved.scheduleTimes == ["09:00", "15:00"])
        #expect(saved.windowModelOverride == "chosen-plan-model")
        #expect(!f.model.engine.triggerDisabledSlugs.contains("sample"))
        #expect(try Data(contentsOf: f.source) == source)
        #expect(!String(decoding: try Data(contentsOf: f.auth), as: UTF8.self).contains("fixture-key"))
        f.model.triggerWindow("sample")
        try await waitForCall(f.model)
        #expect(sent.first?.testModel == "chosen-plan-model")
        #expect(f.model.saveCallModel("sample", model: "separate-validation-model"))
        saved = ProviderConfigStore.read(authFile: f.auth, manifest: f.manifest)
        #expect(saved.scheduleTimes == ["09:00", "15:00"])
        #expect(saved.windowModelOverride == "chosen-plan-model")
        #expect(f.model.saveCallSchedule("sample", times: saved.scheduleTimes, model: "chosen-plan-model", enabled: false))
        #expect(f.model.engine.triggerDisabledSlugs.contains("sample"))
        #expect(try Data(contentsOf: f.source) == source)
    }

    @Test func invalidImportedPlanDoesNotPartiallyWriteOrEnable() throws {
        let f = try fixture { _ in "✓ fixture" }; defer { f.cleanup() }
        let before = try Data(contentsOf: f.auth)
        #expect(!f.model.saveCallSchedule("sample", times: [], timeInput: "9:00", model: "plan", enabled: true))
        #expect(!f.model.saveCallSchedule("sample", times: [], model: "plan", enabled: true))
        #expect(try Data(contentsOf: f.auth) == before)
    }

    @Test func verificationAndWindowResultsRemainIndependent() async throws {
        let f = try fixture { config in config.testModel == "plan-model" ? "HTTP 500: fixture window failure" : "✓ fixture verification" }
        defer { f.cleanup() }
        f.model.testCall("sample", modelOverride: "deepseek/selected")
        f.model.confirmPendingTestCall()
        try await waitForCall(f.model)
        let verification = try #require(f.model.callTestResult(for: "sample"))
        #expect(verification.model == "deepseek/selected" && verification.phase == .success)
        f.model.triggerWindow("sample")
        #expect(f.model.callTestResult(for: "sample")?.date == verification.date)
        try await waitForCall(f.model)
        let window = try #require(f.model.windowCallResult(for: "sample"))
        #expect(window.model == "plan-model" && window.phase == .failure)
        #expect(f.model.callTestResult(for: "sample")?.model == "deepseek/selected")
        #expect(f.model.callTestResult(for: "sample")?.date == verification.date)
        f.model.testCall("sample", modelOverride: "another-validation-model")
        f.model.confirmPendingTestCall()
        try await waitForCall(f.model)
        #expect(f.model.callTestResult(for: "sample")?.model == "another-validation-model")
        #expect(f.model.windowCallResult(for: "sample")?.date == window.date)
    }

    @Test func undeclaredSuppliersCannotTriggerWindows() async throws {
        var calls = 0
        let f = try fixture(window: false) { _ in calls += 1; return "✓ fixture" }; defer { f.cleanup() }
        #expect(!f.model.windowCallConfigured(try #require(f.model.row("sample"))))
        f.model.triggerWindow("sample")
        try await waitForCall(f.model)
        #expect(calls == 0 && f.model.pendingTestConfirmation == nil)
    }

    @Test func planModelScopeRejectsUnlistedPaidFamilies() throws {
        var config = ProviderConfig()
        config.refreshKey = "fixture-key"
        config.refreshUrl = "https://fixture.invalid/v1/chat/completions"
        config.refreshProtocol = "openai"
        config.testModel = "paid/sonnet"
        config.modelCatalog = ProviderModelCatalog(allowedPrefixes: ["cline-pass/"])
        #expect(throws: ProviderAuthenticationError.self) { try RefreshTrigger.callRequest(config: config) }
        config.testModel = "cline-pass/selected"
        #expect(try body(config)["model"] as? String == "cline-pass/selected")
    }

    @Test func transientWindowFeedbackExpiresWhileTheResultRemainsAvailable() {
        let now = Date()
        let success = CallTestResult(phase: .success, model: "plan", target: "fixture", sourceLabel: "5h 窗口调用", message: "ok", date: now)
        #expect(success.feedbackIsVisible(at: now.addingTimeInterval(4)))
        #expect(!success.feedbackIsVisible(at: now.addingTimeInterval(6)))
        let failure = CallTestResult(phase: .failure, model: "plan", target: "fixture", sourceLabel: "5h 窗口调用", message: "error", date: now)
        #expect(failure.feedbackIsVisible(at: now.addingTimeInterval(7)))
        #expect(!failure.feedbackIsVisible(at: now.addingTimeInterval(9)))
        #expect(success.message == "ok" && failure.message == "error")
    }

    @Test func windowDeclarationsAndClineBudgetAreProviderOwned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TokenHUD/providers")
        for slug in ["cline", "glm"] {
            let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: root.appendingPathComponent(slug + "/manifest.json")))
            #expect(manifest.windowTrigger?.period == "five_hour")
            #expect(manifest.windowTrigger?.model.isEmpty == false)
            if slug == "cline" {
                var config = ProviderConfigStore.read(authFile: root.appendingPathComponent("missing.json"), manifest: manifest)
                config.refreshKey = "fixture-key"
                config.testModel = "deepseek/deepseek-v4.1-flash-1017"
                #expect(config.testMaxTokens == 1024)
                let payload = try body(config)
                #expect(payload["model"] as? String == "cline-pass/deepseek-v4.1-flash-1017")
                #expect(payload["max_tokens"] as? Int == 1024)
            }
        }
    }
}
