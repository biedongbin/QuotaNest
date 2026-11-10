import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized) @MainActor
struct ReviewPlanRegressionTests {
    @Test func savedModelAndLocalOverrideAreExplicitPlanIntent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("auth.json")
        let manifest = ProviderManifest(name: "test", label: "T", windowTrigger: ProviderWindowTrigger(period: "five_hour", model: "template"))
        try Data(#"{"testModel":"saved-user-model"}"#.utf8).write(to: file)
        var config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        #expect(config.effectiveScheduleModel(manifest: manifest) == "saved-user-model")
        config.windowModelOverride = "local-plan"
        #expect(config.effectiveScheduleModel(manifest: manifest) == "local-plan")
        config.callModelOverride = "verification-only"
        #expect(config.effectiveScheduleModel(manifest: manifest) == "local-plan")
    }

    @Test func healthAcceptsLocalPlanWithEmptyBaseModelAndRejectsInvalidScope() {
        let manifest = ProviderManifest(name: "test", label: "T", quotaMode: "none")
        var config = ProviderConfig()
        config.refreshKey = "fixture"
        config.refreshUrl = "https://fixture.invalid/v1/chat/completions"
        config.windowModelOverride = "plan/model"
        config.scheduleTimes = ["09:00"]
        config.modelCatalog = ProviderModelCatalog(allowedPrefixes: ["plan/"])
        #expect(AccountHealthAssessment.configuration(manifest: manifest, config: config, scheduleEnabled: true, resolve: { $0 }).isHealthy)
        config.windowModelOverride = "paid/model"
        #expect(!AccountHealthAssessment.configuration(manifest: manifest, config: config, scheduleEnabled: true, resolve: { $0 }).isHealthy)
    }

    @Test func dirtyDefaultAndRestartPreservePendingExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "review-dirty.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func engine() -> DataEngine {
            DataEngine(hudDir: root.appendingPathComponent("hud"), bundleProvidersDir: nil,
                userProvidersDir: root.appendingPathComponent("providers"),
                runner: ProviderRunner(nodePath: nil, logDir: root), defaults: defaults,
                settingsURL: root.appendingPathComponent("settings.json"))
        }
        #expect(!engine().hudNeedsExport)
        let first = engine()
        first.markHUDExportNeeded()
        #expect(engine().hudNeedsExport)
        try Data("invalid-json".utf8).write(to: root.appendingPathComponent("settings.json"))
        if case .success = first.exportHUD() { Issue.record("invalid settings must fail") }
        #expect(first.hudNeedsExport)
        #expect(engine().hudNeedsExport)
    }
}
