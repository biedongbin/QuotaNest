import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
@MainActor
struct SourceReadOnlyTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let auth: URL
        let manifest: URL
        let model: SettingsModel
        let defaults: UserDefaults
        let suite: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(legacy: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-readonly-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.json")
        try Data(#"{"type":"clinepass","api_key":"fixture-source-key","label":"fixture"}"#.utf8).write(to: source)
        let auth = hud.appendingPathComponent(".linked-usage-auth.json")
        let authObject: [String: Any] = ["authMode": "apikey", "testModel": "fixture-model", "quotaMode": "none",
            "refreshApiKey": legacy ? "fixture-legacy-key" : ""]
        try JSONSerialization.data(withJSONObject: authObject).write(to: auth)
        var manifest = ProviderManifest(name: "Linked", label: "Linked", authFile: auth.path,
            testModel: "fixture-model", refreshUrl: "https://api.example.test/v1/messages", refreshProtocol: "anthropic")
        if legacy { manifest.origin = "cpamp:source.json" }
        else {
            manifest.sourceReference = ProviderSourceReference(source: "cpamp", path: source.path,
                recordId: "source.json", providerId: "clinepass")
        }
        try PluginGenerator.writePlugin(slug: "linked", manifest: manifest, script: "exit 1", into: providers)
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let suite = "tokenhud.readonly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
            bundleDir: nil, defaults: defaults, confirmDiscardChanges: { true }, confirmResumePlan: { true },
            executeTestCall: { _ in "offline" }, executeQuotaQuery: { _ in .ok }, confirmDeleteAccount: { true })
        model.selected = "linked"
        return Fixture(root: root, source: source, auth: auth,
            manifest: providers.appendingPathComponent("linked/manifest.json"), model: model,
            defaults: defaults, suite: suite)
    }

    @Test(arguments: [false, true])
    func referenceAndLegacyOriginRejectEditingAndCopy(legacy: Bool) throws {
        let f = try fixture(legacy: legacy); defer { f.cleanup() }
        let beforeSource = try Data(contentsOf: f.source)
        let beforeAuth = try Data(contentsOf: f.auth)
        let beforeManifest = try Data(contentsOf: f.manifest)
        f.model.startEdit()
        #expect(f.model.draft == nil)
        #expect(f.model.topError == SettingsModel.sourceReadOnlyMessage)
        f.model.duplicateAccount("linked")
        #expect(f.model.draft == nil)
        #expect(f.model.engine.allPlugins.count == 1)
        #expect(try Data(contentsOf: f.source) == beforeSource)
        #expect(try Data(contentsOf: f.auth) == beforeAuth)
        #expect(try Data(contentsOf: f.manifest) == beforeManifest)
    }

    @Test(arguments: [false, true])
    func forgedDraftCannotSaveAnySourceConfiguration(legacy: Bool) throws {
        let f = try fixture(legacy: legacy); defer { f.cleanup() }
        let beforeSource = try Data(contentsOf: f.source)
        let beforeAuth = try Data(contentsOf: f.auth)
        let beforeManifest = try Data(contentsOf: f.manifest)
        var values = DraftValues(name: "Changed", url: "https://changed.example.test/v1", key: "replacement-key",
            model: "changed-model", prompt: "changed prompt", proto: "openai", autoQuery: false,
            autoTrigger: true, times: ["09:00"])
        values.authCredentialFile = "/invalid/source.json"
        values.quotaMode = "endpoint"
        values.queryURL = "https://changed.example.test/usage"
        for isNew in [false, true] {
            f.model.draft = Draft(slug: "linked", template: nil, isNew: isNew, values: values, base: DraftValues())
            f.model.save()
            #expect(f.model.topError == SettingsModel.sourceReadOnlyMessage)
            f.model.testCallDraft(values: values)
            #expect(f.model.pendingTestConfirmation == nil)
            #expect(f.model.callRunning.isEmpty)
            #expect(f.model.topError == SettingsModel.sourceReadOnlyMessage)
            let draftConfig = f.model.callConfigForDraft(values)
            #expect(draftConfig.refreshUrl == "https://api.example.test/v1/messages")
            #expect(draftConfig.testModel == "fixture-model")
            #expect(draftConfig.refreshKey.isEmpty)
            #expect(draftConfig.isSourceConfigurationReadOnly)
            #expect(try Data(contentsOf: f.source) == beforeSource)
            #expect(try Data(contentsOf: f.auth) == beforeAuth)
            #expect(try Data(contentsOf: f.manifest) == beforeManifest)
            #expect(f.model.engine.allPlugins.count == 1)
        }
    }

    @Test func localControlsAndDeletionPreserveExternalSource() throws {
        let f = try fixture(); defer { f.cleanup() }
        let beforeSource = try Data(contentsOf: f.source)
        let beforeAuth = try Data(contentsOf: f.auth)
        let beforeManifest = try Data(contentsOf: f.manifest)
        f.model.toggleMonitoring("linked", enabled: false)
        #expect(f.model.engine.disabledSlugs.contains("linked"))
        f.model.toggleMonitoring("linked", enabled: true)
        #expect(!f.model.engine.disabledSlugs.contains("linked"))
        f.model.toggleFloating("linked", shown: false)
        #expect(f.model.engine.floatingHiddenSlugs.contains("linked"))
        f.model.toggleHudSync("linked", synced: false)
        #expect(f.model.engine.hudHiddenSlugs.contains("linked"))
        #expect(try Data(contentsOf: f.auth) == beforeAuth)
        #expect(try Data(contentsOf: f.manifest) == beforeManifest)
        #expect(try Data(contentsOf: f.source) == beforeSource)
        f.model.delete("linked")
        #expect(f.model.engine.allPlugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.manifest.path))
        #expect(try Data(contentsOf: f.source) == beforeSource)
    }

    @Test func sourceLocationRemovesURLCredentialsAndParameters() {
        let location = SettingsModel.safeSourceLocation("https://user:private@example.test/config?token=private#private")
        #expect(location == "https://example.test/config")
        #expect(SettingsModel.safeSourceLocation("/tmp/fixture.json") == "/tmp/fixture.json")
    }
}
