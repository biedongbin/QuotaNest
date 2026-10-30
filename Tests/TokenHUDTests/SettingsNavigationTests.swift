import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct SettingsNavigationTests {
    private func makeModel(
        confirmDiscardChanges: (() -> Bool)? = nil
    ) throws -> (SettingsModel, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-nav-\(UUID().uuidString)", isDirectory: true)
        let hud = root.appendingPathComponent("hud", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let suite = "tokenhud.nav-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        for (slug, name, times) in [("alpha", "Alpha", ["09:00"]), ("beta", "Beta", ["10:30"])] {
            let auth = hud.appendingPathComponent(".\(slug)-usage-auth.json")
            let manifest = ProviderManifest(name: slug, label: name, authFile: auth.path,
                                            refreshUrl: "https://example.test/v1/chat/completions",
                                            authMode: "apikey")
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "", into: providers)
            let cfg = try JSONSerialization.data(withJSONObject: ["scheduleTimes": times])
            try cfg.write(to: auth)
        }

        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root), defaults: defaults,
                                settingsURL: root.appendingPathComponent("settings.json"))
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
                                  settingsURL: root.appendingPathComponent("settings.json"),
                                  bundleDir: nil, defaults: defaults,
                                  confirmDiscardChanges: confirmDiscardChanges)
        return (model, root, defaults, suite)
    }

    private func cleanup(_ root: URL, _ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func topLevelPagesDoNotSelectFirstAccount() throws {
        let (model, root, defaults, suite) = try makeModel()
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("beta", tab: .config))
        model.navigate(to: .plan)
        #expect(model.navPage == .plan)
        #expect(model.selected == "beta")
        #expect(model.tab == .config)
        model.navigate(to: .settings)
        #expect(model.navPage == .settings)
        #expect(model.selected == "beta")
        #expect(model.tab == .config)
        model.navigate(to: .overview)
        #expect(model.navPage == .overview)
    }

    @Test func addingFromEachPageRestoresOriginOnCancel() throws {
        let (model, root, defaults, suite) = try makeModel()
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("beta", tab: .trigger))
        for page in [SettingsModel.NavPage.overview, .plan, .settings, .detail] {
            model.navigate(to: page)
            model.openTemplates()
            #expect(model.navPage == .detail)
            #expect(model.showingTemplates)
            model.closeTemplates()
            #expect(model.navPage == page)
            #expect(!model.showingTemplates)
            #expect(model.selected == "beta")
            #expect(model.tab == .trigger)
        }
    }

    @Test func searchOnlyFiltersOverviewAccounts() throws {
        let (model, root, defaults, suite) = try makeModel()
        defer { cleanup(root, defaults, suite) }
        model.search = "Alpha"
        #expect(model.accounts.map(\.id) == ["alpha"])
        #expect(Set(model.allAccounts.map(\.id)) == ["alpha", "beta"])
        #expect(Set(model.planRows.map(\.id)) == ["alpha", "beta"])
        #expect(Set(model.allAccounts.filter(\.enabled).map(\.id)) == ["alpha", "beta"])
    }

    @Test func decliningDraftDiscardDoesNotChangePageAccountOrTab() throws {
        let (model, root, defaults, suite) = try makeModel(confirmDiscardChanges: { false })
        defer { cleanup(root, defaults, suite) }
        #expect(model.selectAccount("beta", tab: .config))
        model.startEdit()
        model.draft?.values.name = "未保存名称"
        #expect(model.draft?.dirty == true)
        #expect(!model.selectAccount("alpha", tab: .trigger))
        #expect(model.navPage == .detail)
        #expect(model.selected == "beta")
        #expect(model.tab == .config)
        #expect(model.draft?.values.name == "未保存名称")
        model.navigate(to: .plan)
        #expect(model.navPage == .detail)
        #expect(model.tab == .config)
    }

    @Test func deletionOwnershipPreservesExternalSourcesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-delete-\(UUID().uuidString)", isDirectory: true)
        let hud = root.appendingPathComponent("hud", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for directory in [hud, providers, external] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let externalAuth = external.appendingPathComponent("auth.json")
        let externalCache = external.appendingPathComponent("cache.json")
        try Data("external-auth".utf8).write(to: externalAuth)
        try Data("external-cache".utf8).write(to: externalCache)
        let linkedAuth = hud.appendingPathComponent(".alpha-usage-auth.json")
        let linkedCache = hud.appendingPathComponent(".alpha-usage-cache.json")
        try fm.createSymbolicLink(at: linkedAuth, withDestinationURL: externalAuth)
        try fm.createSymbolicLink(at: linkedCache, withDestinationURL: externalCache)
        let linkedPlugin = providers.appendingPathComponent("alpha", isDirectory: true)
        try fm.createSymbolicLink(at: linkedPlugin, withDestinationURL: external)

        #expect(!AccountFileOwnership.canRemoveHUDFile(externalAuth, slug: "alpha", kind: .auth, hudDir: hud))
        #expect(!AccountFileOwnership.canRemoveHUDFile(externalCache, slug: "alpha", kind: .cache, hudDir: hud))
        #expect(!AccountFileOwnership.canRemoveHUDFile(linkedAuth, slug: "alpha", kind: .auth, hudDir: hud))
        #expect(!AccountFileOwnership.canRemoveHUDFile(linkedCache, slug: "alpha", kind: .cache, hudDir: hud))
        #expect(!AccountFileOwnership.canRemovePluginDirectory(linkedPlugin, slug: "alpha", userDir: providers))
        #expect(!AccountFileOwnership.canRemovePluginDirectory(external, slug: "alpha", userDir: providers))
        #expect(try String(contentsOf: externalAuth, encoding: .utf8) == "external-auth")
        #expect(try String(contentsOf: externalCache, encoding: .utf8) == "external-cache")
    }

    @Test func deletionOwnershipAllowsOnlyExactAppOwnedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-delete-owned-\(UUID().uuidString)", isDirectory: true)
        let hud = root.appendingPathComponent("hud", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: hud, withIntermediateDirectories: true)
        try fm.createDirectory(at: providers, withIntermediateDirectories: true)
        let auth = hud.appendingPathComponent(".alpha-usage-auth.json")
        let cache = hud.appendingPathComponent(".alpha-usage-cache.json")
        let plugin = providers.appendingPathComponent("alpha", isDirectory: true)
        try Data("owned-auth".utf8).write(to: auth)
        try Data("owned-cache".utf8).write(to: cache)
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)

        #expect(AccountFileOwnership.canRemoveHUDFile(auth, slug: "alpha", kind: .auth, hudDir: hud))
        #expect(AccountFileOwnership.canRemoveHUDFile(cache, slug: "alpha", kind: .cache, hudDir: hud))
        #expect(AccountFileOwnership.canRemovePluginDirectory(plugin, slug: "alpha", userDir: providers))
        #expect(!AccountFileOwnership.canRemoveHUDFile(auth, slug: "beta", kind: .auth, hudDir: hud))
        #expect(!AccountFileOwnership.canRemovePluginDirectory(plugin, slug: "../alpha", userDir: providers))
        if AccountFileOwnership.canRemoveHUDFile(auth, slug: "alpha", kind: .auth, hudDir: hud) {
            try fm.removeItem(at: auth)
        }
        if AccountFileOwnership.canRemoveHUDFile(cache, slug: "alpha", kind: .cache, hudDir: hud) {
            try fm.removeItem(at: cache)
        }
        if AccountFileOwnership.canRemovePluginDirectory(plugin, slug: "alpha", userDir: providers) {
            try fm.removeItem(at: plugin)
        }
        #expect(!fm.fileExists(atPath: auth.path))
        #expect(!fm.fileExists(atPath: cache.path))
        #expect(!fm.fileExists(atPath: plugin.path))
    }

    @Test func planReportsRecordedStateWithoutClaimingSuccess() throws {
        let (model, root, defaults, suite) = try makeModel()
        defer { cleanup(root, defaults, suite) }
        let day = DataEngine.scheduleKey(slug: "alpha").split(separator: "|").first.map(String.init)!
        let recorded: [String: [String: String]] = [
            "\(day)|alpha": ["09:00": "fired"],
            "\(day)|beta": ["10:30": "skipped:busy"],
        ]
        let data = try JSONEncoder().encode(recorded)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: DataEngine.defaultsScheduleFiredKey)
        let rows = model.planRows
        #expect(rows.first { $0.id == "alpha" }?.lastOutcome == "09:00 已登记，调用结果未知")
        #expect(rows.first { $0.id == "beta" }?.lastOutcome == "10:30 跳过：调用繁忙")
        #expect(rows.first { $0.id == "alpha" }?.times == ["09:00"])
    }
}
