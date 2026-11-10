import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
@MainActor
struct AccountControlTests {
    private func makeModel(confirmResume: @escaping () -> Bool) throws -> (SettingsModel, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-account-control-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        let suite = "tokenhud.account-control.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let auth = hud.appendingPathComponent(".fixture-usage-auth.json")
        let manifest = ProviderManifest(name: "fixture", label: "Fixture", authFile: auth.path,
                                        queryUrl: "https://example.test/usage", queryKeyField: "apiKey",
                                        refreshUrl: "https://example.test/v1/chat/completions", authMode: "apikey")
        let wrapper = """
        #!/bin/zsh
        set -eu
        export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-$HOME/.claude/hud}"
        "${TOKENHUD_NODE:-node}" "$TOKENHUD_HUD_DIR/generic-usage-provider.mjs"
        """
        try PluginGenerator.writePlugin(slug: "fixture", manifest: manifest, script: wrapper, into: providers)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let bundleProviders = bundle.appendingPathComponent("providers", isDirectory: true)
        let bundleMjs = bundle.appendingPathComponent("mjs", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleProviders, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleMjs, withIntermediateDirectories: true)
        for name in HUDFixtures.runtimeScriptNames {
            try Data("// fixture runtime".utf8).write(to: bundleMjs.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject: ["apiKey": "fixture-key", "scheduleTimes": ["09:00"]]).write(to: auth)
        defaults.set(["fixture"], forKey: DataEngine.defaultsFloatingHiddenKey)
        defaults.set(["fixture"], forKey: DataEngine.defaultsHudHiddenKey)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: bundleProviders, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: root.appendingPathComponent("settings.json"),
                                runtimeDir: root.appendingPathComponent("runtime", isDirectory: true))
        engine.reloadRegistry()
        try Data("{\"env\":{}}".utf8).write(to: root.appendingPathComponent("settings.json"))
        engine.setFloatingHidden("fixture", hidden: true)
        engine.setHudHidden("fixture", hidden: true)
        engine.setTracking("fixture", enabled: false)
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
                                  settingsURL: root.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: defaults, confirmResumePlan: confirmResume)
        return (model, root, defaults, suite)
    }

    private func clean(_ root: URL, _ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func enablingAccountSynchronizesDraftGateWithoutDiscardingEdits() throws {
        let (model, root, defaults, suite) = try makeModel(confirmResume: { true })
        defer { clean(root, defaults, suite) }
        #expect(model.selectAccount("fixture", tab: .config))
        model.startEdit()
        model.draft?.values.name = "未保存名称"
        model.toggleMonitoring("fixture", enabled: true)
        #expect(model.row("fixture")?.enabled == true)
        #expect(model.draft?.values.autoQuery == true)
        #expect(model.draft?.base.autoQuery == true)
        #expect(model.draft?.values.name == "未保存名称")
        #expect(model.draft?.dirty == true)
        #expect(model.engine.floatingHiddenSlugs.contains("fixture"))
        #expect(model.engine.hudHiddenSlugs.contains("fixture"))
        #expect(model.readConfig(try #require(model.row("fixture")).plugin).scheduleTimes == ["09:00"])
        model.toggleMonitoring("fixture", enabled: false)
        #expect(model.draft?.values.autoQuery == false)
        #expect(model.draft?.base.autoQuery == false)
        #expect(model.draft?.values.name == "未保存名称")
    }

    @Test func hudSelectionUsesOnePreferenceAndProjectionFromEitherPage() throws {
        let (model, root, defaults, suite) = try makeModel(confirmResume: { true })
        defer { clean(root, defaults, suite) }
        model.engine.setTracking("fixture", enabled: true)
        // Both global settings and the supplier display page call this same operation.
        model.toggleHudSync("fixture", synced: true)
        #expect(!model.engine.hudHiddenSlugs.contains("fixture"))
        #expect(!(defaults.stringArray(forKey: DataEngine.defaultsHudHiddenKey) ?? []).contains("fixture"))
        #expect(model.engine.hudSyncNames.contains("fixture"))
        let settingsURL = root.appendingPathComponent("settings.json")
        // Selection is local; only the explicit export writes settings/envs.
        #expect(model.engine.hudNeedsExport)
        let untouched = try Data(contentsOf: settingsURL)
        #expect(try JSONSerialization.jsonObject(with: untouched) is [String: Any])
        if case .failure(let error) = model.engine.exportHUD() { Issue.record("导出失败：\(error)") }
        #expect(!model.engine.hudNeedsExport)
        let restarted = DataEngine(hudDir: root.appendingPathComponent("hud"), bundleProvidersDir: nil,
            userProvidersDir: root.appendingPathComponent("providers"), runner: ProviderRunner(nodePath: nil, logDir: root),
            defaults: defaults, settingsURL: settingsURL)
        #expect(!restarted.hudNeedsExport)
        let selected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        #expect((selected["env"] as? [String: String])?["ACCOUNT_ENVS"] == "fixture")
        model.toggleHudSync("fixture", synced: false)
        #expect(model.engine.hudHiddenSlugs.contains("fixture"))
        #expect((defaults.stringArray(forKey: DataEngine.defaultsHudHiddenKey) ?? []).contains("fixture"))
        #expect(!model.engine.hudSyncNames.contains("fixture"))
        if case .failure(let error) = model.engine.exportHUD() { Issue.record("导出失败：\(error)") }
        let hidden = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        #expect((hidden["env"] as? [String: String])?["ACCOUNT_ENVS"] == "")
    }

    @Test func baseEditorSaveUpdatesExplicitPlanModelAndRequest() throws {
        let (model, root, defaults, suite) = try makeModel(confirmResume: { true })
        defer { clean(root, defaults, suite) }
        let plugin = try #require(model.row("fixture")).plugin
        let auth = try #require(model.authURL(plugin))
        var config = model.readConfig(plugin)
        config.testModel = "old-base"
        config.windowModelOverride = "old-plan"
        try ProviderConfigStore.write(config, manifest: plugin.manifest, to: auth)
        #expect(model.selectAccount("fixture", tab: .config))
        model.startEdit()
        #expect(model.callConfigForDraft(try #require(model.draft).values).effectiveScheduleModel(manifest: plugin.manifest) == "old-plan")
        model.draft?.values.model = "user-chosen"
        model.save()
        #expect(model.draft == nil)
        let savedPlugin = try #require(model.row("fixture")).plugin
        let saved = model.readConfig(savedPlugin)
        let request = try RefreshTrigger.scheduleRequest(config: saved, manifest: savedPlugin.manifest)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "user-chosen")
        #expect(saved.effectiveScheduleModel(manifest: savedPlugin.manifest) == "user-chosen")
    }

    @Test(arguments: [false, true])
    func savingVerificationModelPreservesIndependentAccountPlanModel(missingBase: Bool) throws {
        let (model, root, defaults, suite) = try makeModel(confirmResume: { true })
        defer { clean(root, defaults, suite) }
        var plugin = try #require(model.row("fixture")).plugin
        if missingBase {
            var manifest = plugin.manifest
            manifest.testModel = "template-base"
            manifest.windowTrigger = ProviderWindowTrigger(period: "five_hour", model: "plan-A")
            try JSONEncoder().encode(manifest).write(to: plugin.dir.appendingPathComponent("manifest.json"))
            model.engine.reloadRegistry()
            plugin = try #require(model.row("fixture")).plugin
        }
        #expect(plugin.manifest.sourceReference == nil)
        let auth = try #require(model.authURL(plugin))
        var initial = model.readConfig(plugin)
        initial.testModel = "plan-A"
        initial.windowModelOverride = nil
        try ProviderConfigStore.write(initial, manifest: plugin.manifest, to: auth)
        if missingBase {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
            object["testModel"] = nil
            try JSONSerialization.data(withJSONObject: object).write(to: auth)
        }
        func requestModel(_ request: URLRequest) throws -> String? {
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return body["model"] as? String
        }
        let before = model.readConfig(plugin)
        #expect(try requestModel(RefreshTrigger.scheduleRequest(config: before, manifest: plugin.manifest)) == "plan-A")
        for verification in ["verification-B", "verification-C"] {
            #expect(model.saveCallModel("fixture", model: verification))
            let saved = model.readConfig(plugin)
            #expect(saved.windowModelOverride == nil)
            #expect(saved.savedScheduleModel == (missingBase ? nil : "plan-A"))
            #expect(try requestModel(RefreshTrigger.scheduleRequest(config: saved, manifest: plugin.manifest)) == "plan-A")
            #expect(try requestModel(RefreshTrigger.callRequest(config: saved)) == verification)
        }
        guard !missingBase else { return }
        #expect(model.selectAccount("fixture", tab: .config))
        model.startEdit()
        #expect(model.draft?.values.model == "plan-A")
        model.draft?.values.name = "Rename without changing plan"
        model.save()
        let renamed = try #require(model.row("fixture")).plugin
        #expect(try requestModel(RefreshTrigger.scheduleRequest(config: model.readConfig(renamed), manifest: renamed.manifest)) == "plan-A")
    }

    @Test func cancellingPlanResumeLeavesAccountAndDraftUnchanged() throws {
        let (model, root, defaults, suite) = try makeModel(confirmResume: { false })
        defer { clean(root, defaults, suite) }
        #expect(model.selectAccount("fixture", tab: .config))
        model.startEdit()
        model.draft?.values.name = "继续编辑"
        let before = model.draft
        model.toggleMonitoring("fixture", enabled: true)
        #expect(model.row("fixture")?.enabled == false)
        #expect(model.draft == before)
        #expect(model.engine.floatingHiddenSlugs.contains("fixture"))
        #expect(model.engine.hudHiddenSlugs.contains("fixture"))
        #expect(!model.engine.triggerDisabledSlugs.contains("fixture"))
    }
}
