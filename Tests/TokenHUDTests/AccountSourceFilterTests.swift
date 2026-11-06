import Foundation
import Testing
@testable import QuotaNest

@Suite @MainActor struct AccountSourceFilterTests {
    @Test func sourceKindsIncludeManualReferencedLegacyAndNewTools() {
        var manifest = ProviderManifest(name: "Sample", label: "Sample")
        #expect(AccountSourceFilter.origin(of: manifest) == .manual)
        manifest.origin = "cc-switch:record-A"
        #expect(AccountSourceFilter.origin(of: manifest) == .imported("cc-switch"))
        manifest.sourceReference = ProviderSourceReference(source: "magpie", path: "/fixture.json", recordId: "A")
        #expect(AccountSourceFilter.origin(of: manifest) == .imported("magpie"))
        manifest.sourceReference = nil; manifest.origin = "custom-tool:A"
        #expect(AccountSourceFilter.imported("custom-tool").includes(manifest))
        #expect(!AccountSourceFilter.manual.includes(manifest))
        #expect(AccountSourceFilter.all.includes(manifest))
    }

    @Test func sourceFilterCombinesWithSearchAndStatusWithoutChangingAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-filter-\(UUID())")
        let providers = root.appendingPathComponent("providers"), hud = root.appendingPathComponent("hud")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (slug, name, source) in [("manual", "Work manual", ""), ("magpie", "Work imported", "magpie"), ("cc", "Personal imported", "cc-switch")] {
            var manifest = ProviderManifest(name: slug, label: "Fixture", displayName: name,
                authFile: hud.appendingPathComponent(".\(slug)-usage-auth.json").path)
            if !source.isEmpty { manifest.origin = source + ":record" }
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "exit 0", into: providers)
        }
        let suite = "source.filter.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = root.appendingPathComponent("settings.json")
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings, bundleDir: nil, defaults: defaults)
        model.sidebarStatusFilter = .all
        #expect(model.accounts.count == 3)
        #expect(Set(model.availableSourceFilters) == [.all, .manual, .imported("magpie"), .imported("cc-switch")])
        model.sourceFilter = .imported("magpie"); model.search = "Work"
        #expect(model.accounts.map(\.id) == ["magpie"])
        #expect(model.overviewGroups.flatMap(\.rows).count == 1 && model.sidebarGroups.flatMap(\.rows).count == 1)
        model.search = "Personal"
        #expect(model.accounts.isEmpty)
        model.search = ""; model.sourceFilter = .manual
        engine.setTracking("manual", enabled: false)
        model.sidebarStatusFilter = .disabled
        #expect(model.sidebarGroups.flatMap(\.rows).map(\.id) == ["manual"])
        #expect(model.allAccounts.count == 3 && ProviderRegistry.scan(dir: providers).count == 3)
    }
}
