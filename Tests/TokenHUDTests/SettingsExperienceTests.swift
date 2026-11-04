import AppKit
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct SettingsExperienceTests {
    private func fixture(confirm: ((CallTestConfirmation) -> Bool)? = nil,
                         execute: ((ProviderConfig) async -> String?)? = nil,
                         confirmDiscard: (() -> Bool)? = nil,
                         confirmPlan: (() -> Bool)? = nil)
        throws -> (SettingsModel, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-experience-\(UUID().uuidString)", isDirectory: true)
        let hud = root.appendingPathComponent("hud", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let suite = "tokenhud.experience.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let auth = hud.appendingPathComponent(".sample-usage-auth.json")
        let manifest = ProviderManifest(name: "Sample", label: "Sample", authFile: auth.path,
                                        refreshUrl: "https://example.test/v1/chat/completions",
                                        refreshProtocol: "openai", refreshAuth: "bearer",
                                        refreshHeader: "X-Fixture-Key: <key>", authMode: "apikey")
        try PluginGenerator.writePlugin(slug: "sample", manifest: manifest, script: "exit 1", into: providers)
        try JSONSerialization.data(withJSONObject: ["refreshApiKey": "disk-key", "testModel": "saved-model",
                                                    "testPrompt": "saved-prompt", "scheduleTimes": ["09:00"]])
            .write(to: auth)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: root.appendingPathComponent("settings.json"))
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
                                  settingsURL: root.appendingPathComponent("settings.json"),
                                  bundleDir: nil, defaults: defaults,
                                  confirmDiscardChanges: confirmDiscard, confirmResumePlan: confirmPlan,
                                  confirmTestCall: confirm, executeTestCall: execute)
        return (model, root, defaults, suite)
    }

    private func cleanup(_ root: URL, _ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func activationPolicyKeepsMinimizedAndCancelledWindowsSwitchable() {
        #expect(SettingsWindowLifecycle.activationPolicy(after: .show) == .regular)
        #expect(SettingsWindowLifecycle.activationPolicy(after: .minimize) == .regular)
        #expect(SettingsWindowLifecycle.activationPolicy(after: .closeCancelled) == .regular)
        #expect(SettingsWindowLifecycle.activationPolicy(after: .closeAccepted) == .accessory)
    }

    @Test func currentDraftIsTestedWithoutChangingSavedConfigurationOrQuota() async throws {
        var sent: ProviderConfig?
        var confirmation: CallTestConfirmation?
        let (model, root, defaults, suite) = try fixture(confirm: { confirmation = $0; return true },
                                                        execute: { sent = $0; return "✓ fixture" })
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("sample", tab: .config))
        model.startEdit()
        model.draft?.values.url = "https://current.example.test"
        model.draft?.values.model = "current-model"
        model.draft?.values.prompt = "current-prompt"
        model.draft?.values.key = "new-key"
        let auth = root.appendingPathComponent("hud/.sample-usage-auth.json")
        let before = try Data(contentsOf: auth)
        let values = try #require(model.draft?.values)
        model.testCallDraft(values: values)
        for _ in 0..<30 where model.isTestingCurrentConfig { await Task.yield() }
        #expect(sent?.testModel == "current-model")
        #expect(sent?.testPrompt == "current-prompt")
        #expect(sent?.refreshKey == "new-key")
        #expect(sent?.refreshUrl == "https://current.example.test/v1/chat/completions")
        #expect(sent?.refreshHeader == "X-Fixture-Key: <key>")
        #expect(confirmation?.sourceLabel == "当前输入")
        #expect(try Data(contentsOf: auth) == before)
        #expect(model.draft?.dirty == true)
        #expect(model.engine.states.first?.cache == nil)
        #expect(model.callTestResult(for: "sample")?.phase == .success)
        #expect(model.callTestResult(for: "sample")?.model == "current-model")
        model.draft?.values.model = "later-edit"
        #expect(model.callTestResult(for: "sample")?.model == "current-model")
    }

    @Test func clearingSharedKeyAndCancellingConfirmationSendNothing() async throws {
        var calls = 0
        var confirmations = 0
        let (model, root, defaults, suite) = try fixture(confirm: { _ in confirmations += 1; return false },
                                                        execute: { _ in calls += 1; return "✓ fixture" })
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("sample", tab: .config))
        model.startEdit()
        model.draft?.values.url = "https://example.test"
        let before = try Data(contentsOf: root.appendingPathComponent("hud/.sample-usage-auth.json"))
        model.testCallDraft(values: try #require(model.draft?.values))
        #expect(confirmations == 1)
        #expect(calls == 0)
        model.draft?.values.key = ""
        model.draft?.values.clearKeyIntent = true
        model.testCallDraft(values: try #require(model.draft?.values))
        #expect(confirmations == 1)
        #expect(calls == 0)
        #expect(model.callTestResult(for: "sample")?.phase == .failure)
        #expect(try Data(contentsOf: root.appendingPathComponent("hud/.sample-usage-auth.json")) == before)
    }

    @Test func savingDiscardsOldQueryCredentialsAndPreservesBaseAuthentication() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { cleanup(root, defaults, suite) }
        let auth = root.appendingPathComponent("hud/.sample-usage-auth.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "quotaCredentialMode": "legacy", "queryKey": "old-query-key",
            "token": "old-token", "cookie": "old-cookie", "queryToken": "old-query-token",
            "queryCookie": "old-query-cookie", "headers": ["Authorization": "Bearer query-key"],
            "refreshApiKey": "call-key", "testModel": "saved-model", "testPrompt": "saved-prompt"])
        try data.write(to: auth)
        #expect(model.selectAccount("sample", tab: .config))
        model.startEdit()
        #expect(model.draft?.values.key == "call-key")
        model.draft?.values.name = "Name change"
        model.draft?.values.autoTrigger = false
        model.save()
        #expect(model.topError.isEmpty)
        var config = model.readConfig(try #require(model.current?.plugin))
        #expect(config.queryKey.isEmpty)
        #expect(config.refreshKey == "call-key")
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        for field in ["quotaCredentialMode", "queryKey", "queryToken", "queryCookie", "token", "cookie", "headers"] {
            #expect(saved[field] == nil)
        }
        model.startEdit()
        #expect(model.draft?.hasExistingKey == true)
        model.draft?.values.key = "replacement-base-key"
        model.save()
        config = model.readConfig(try #require(model.current?.plugin))
        #expect(config.queryKey.isEmpty)
        #expect(config.refreshKey == "replacement-base-key")
        model.startEdit()
        model.draft?.values.key = ""
        model.draft?.values.clearKeyIntent = true
        model.save()
        config = model.readConfig(try #require(model.current?.plugin))
        #expect(config.queryKey.isEmpty)
        #expect(config.refreshKey.isEmpty)
        #expect(!model.callConfigured(try #require(model.current)))
    }

    @Test func newPlanCancellationKeepsDraftAndCreatesNoAccount() throws {
        var confirmations = 0
        let (model, root, defaults, suite) = try fixture(confirmPlan: { confirmations += 1; return false })
        defer { cleanup(root, defaults, suite) }
        let choice = try #require(model.choices.first { $0.id == "generic-openai" })
        model.pickTemplate(choice)
        model.draft?.values.name = "New fixture"
        model.draft?.values.url = "https://new.example.test"
        model.draft?.values.key = "fake-key"
        model.draft?.values.model = "fake-model"
        model.draft?.values.autoTrigger = true
        model.draft?.values.times = ["15:30"]
        model.save()
        #expect(confirmations == 1)
        #expect(model.draft?.isNew == true)
        #expect(model.topError.contains("取消保存"))
        #expect(model.engine.allPlugins.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("hud/.new-fixture-usage-auth.json").path))
    }

    @Test func newDraftResultMovesToSavedAccountAndRunningTestBlocksSave() async throws {
        var release = false
        let (model, root, defaults, suite) = try fixture(confirm: { _ in true }, execute: { _ in
            while !release { await Task.yield() }
            return "✓ fixture"
        })
        defer { cleanup(root, defaults, suite) }
        model.pickTemplate(try #require(model.choices.first { $0.id == "generic-openai" }))
        model.draft?.values.name = "New fixture"
        model.draft?.values.url = "https://new.example.test"
        model.draft?.values.key = "fake-key"
        model.draft?.values.model = "fake-model"
        let temporaryKey = model.callTestResultKey
        model.testCallDraft(values: try #require(model.draft?.values))
        model.save()
        #expect(model.draft?.isNew == true)
        #expect(model.topError.contains("测试调用进行中"))
        release = true
        for _ in 0..<30 where model.isTestingCurrentConfig { await Task.yield() }
        #expect(model.callTestResult(for: nil)?.phase == .success)
        model.save()
        #expect(model.topError.isEmpty)
        let slug = try #require(model.selected)
        #expect(slug != temporaryKey)
        #expect(model.callTestResults[temporaryKey] == nil)
        #expect(model.callTestResult(for: slug)?.phase == .success)
        #expect(model.callTestResult(for: slug)?.sourceLabel == "当前输入")
    }

    @Test func pendingTimeRequiresDiscardConfirmation() throws {
        let (model, root, defaults, suite) = try fixture(confirmDiscard: { false })
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("sample", tab: .trigger))
        model.startEdit()
        model.draft?.timeInput = "15:30"
        #expect(model.draft?.dirty == true)
        model.navigate(to: .overview)
        #expect(model.navPage == .detail)
        #expect(model.draft?.timeInput == "15:30")
    }

    @Test func localExternalCredentialFileIsReadOnlyWhenSaving() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { cleanup(root, defaults, suite) }
        let external = root.appendingPathComponent("external-cli-auth.json")
        let contents = Data("{\"fixture\":\"must-stay\"}".utf8)
        try contents.write(to: external)
        let manifest = ProviderManifest(name: "External", label: "External", authFile: external.path,
                                        queryAuth: "header", template: "local", authMode: "local")
        try PluginGenerator.writePlugin(slug: "external", manifest: manifest, script: "exit 1", into: model.userDir)
        model.engine.reloadRegistry()
        #expect(model.selectAccount("external", tab: .config))
        model.startEdit()
        model.draft?.values.name = "Renamed"
        model.save()
        #expect(model.topError.contains("外部只读"))
        #expect(try Data(contentsOf: external) == contents)
        #expect(model.draft?.dirty == true)
    }

    @Test func resultTargetDoesNotExposeURLCredentialsOrQuery() {
        #expect(CallTestResult.targetDescription("https://person:secret@example.test/v1/messages?token=private#key")
                == "https://example.test/v1/messages")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_SETTINGS_WINDOW_TESTS"] == "1"))
    func actualWindowReopensOneInstanceAndHonorsCloseGuard() async throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        var discardAllowed = false
        let (model, root, defaults, suite) = try fixture(confirmDiscard: { discardAllowed })
        defer { cleanup(root, defaults, suite); app.setActivationPolicy(originalPolicy) }
        let manager = SettingsWindowManager(defaults: defaults, autosaveName: "fixture-\(UUID().uuidString)")
        manager.makeModel = { model }
        let before = Set(app.windows.map(ObjectIdentifier.init))
        manager.show()
        let window = try #require(app.windows.first { !before.contains(ObjectIdentifier($0)) && $0 is SettingsMainWindow })
        defer { window.close() }
        for _ in 0..<5 where !window.isKeyWindow {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(app.activationPolicy() == .regular)
        #expect(window.isVisible)
        // CLI test hosts cannot establish macOS foreground focus; verify key-window capability here.
        // Actual focus activation remains an explicit manual acceptance step for the packaged App.
        #expect(window.canBecomeKey)
        let number = window.windowNumber
        window.miniaturize(nil)
        #expect(app.activationPolicy() == .regular)
        manager.show()
        #expect(!window.isMiniaturized)
        #expect(window.windowNumber == number)
        #expect(app.windows.filter { !before.contains(ObjectIdentifier($0)) && $0 is SettingsMainWindow }.count == 1)
        #expect(model.selectAccount("sample", tab: .config))
        model.startEdit()
        model.draft?.values.name = "Unsubmitted edit"
        #expect(model.draft?.dirty == true)
        window.performClose(nil)
        #expect(window.isVisible)
        #expect(app.activationPolicy() == .regular)
        #expect(model.draft?.values.name == "Unsubmitted edit")
        discardAllowed = true
        window.performClose(nil)
        #expect(!window.isVisible)
        #expect(app.activationPolicy() == .accessory)
        manager.show()
        #expect(window.windowNumber == number)
        #expect(window.isVisible)
        #expect(app.activationPolicy() == .regular)
        #expect(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) })
    }

    @Test func savingConfigurationKeepsTheConfigurationPageWithoutSendingRequests() async throws {
        let (model, root, defaults, suite) = try fixture()
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("sample", tab: .config))
        model.startEdit()
        model.draft?.values.name = "Renamed"
        model.draft?.values.autoTrigger = false
        model.save()
        #expect(model.topError.isEmpty)
        #expect(model.tab == .config)
        #expect(model.navPage == .detail)
        #expect(model.draft == nil)
        #expect(model.engine.states.first?.cache == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
    }
}
