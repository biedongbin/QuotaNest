import Foundation
import Testing
@testable import TokenHUD

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
        try PluginGenerator.writePlugin(slug: "fixture", manifest: manifest, script: "", into: providers)
        try JSONSerialization.data(withJSONObject: ["apiKey": "fixture-key", "scheduleTimes": ["09:00"]]).write(to: auth)
        defaults.set(["fixture"], forKey: DataEngine.defaultsFloatingHiddenKey)
        defaults.set(["fixture"], forKey: DataEngine.defaultsHudHiddenKey)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: root.appendingPathComponent("settings.json"))
        engine.reloadRegistry()
        try Data("{\"env\":{}}".utf8).write(to: root.appendingPathComponent("settings.json"))
        engine.setFloatingHidden("fixture", hidden: true)
        try engine.setHudHidden("fixture", hidden: true).get()
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
