import Foundation
import Testing
@testable import TokenHUD

@Suite struct ImportEligibilityTests {
    private func candidate(template: String? = "demo", reason: String? = nil,
                           mode: String = "apikey") -> ImportCandidate {
        ImportCandidate(source: "9router", name: "Fixture", template: template, apiKey: "",
                        baseURL: "", proto: "openai", note: "", unsupportedReason: reason,
                        sourceRecordId: "record-1",
                        sourceReference: ProviderSourceReference(source: "9router", path: "/fixture/db.sqlite",
                            recordId: "record-1", providerId: "demo", collection: "providerConnections"),
                        sourceAuthMode: mode)
    }

    @Test func adapterCapabilityDoesNotProveSourceImportability() {
        let row = candidate(reason: "来源授权结构未匹配该类型声明的 Auth 格式")
        let manifest = ProviderManifest(name: "Demo", label: "Demo", quotaMode: "script", quotaAuthModes: ["apikey"])
        #expect(ImportCenterModel.quotaAdapted(row, templateLookup: { _ in manifest }))
        let state = ImportCenterModel.stateOf(row, existing: [], templateLookup: { _ in manifest })
        #expect(state == .unsupported)
        #expect(!state.pickable)
    }

    @Test func missingQuotaAndUnsupportedModeCannotBeSelectedEvenForLegacyConversion() {
        let row = candidate()
        let legacy = PluginProvider(slug: "legacy", manifest: ProviderManifest(name: "Demo", label: "Demo", origin: row.origin),
                                    dir: URL(fileURLWithPath: "/fixture/legacy"))
        for manifest in [ProviderManifest(name: "Demo", label: "Demo", quotaMode: "none"),
                         ProviderManifest(name: "Demo", label: "Demo", quotaMode: "script", quotaAuthModes: ["auth"])] {
            #expect(!ImportCenterModel.quotaAdapted(row, templateLookup: { _ in manifest }))
            let state = ImportCenterModel.stateOf(row, existing: [legacy], templateLookup: { _ in manifest })
            #expect(state == .unadapted)
            #expect(!state.pickable)
        }
        #expect(!ImportCenterModel.quotaAdapted(candidate(template: nil), templateLookup: { _ in nil }))
        #expect(!ImportCenterModel.quotaAdapted(row, templateLookup: { _ in nil }))
        #expect(ImportCenterModel.RowState.addable.pickable)
        #expect(ImportCenterModel.RowState.convertible.pickable)
        #expect(!ImportCenterModel.RowState.exists.pickable)
    }

    @Test @MainActor func disabledRowsRejectIndividualBulkAndForcedSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "import-disabled-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hud = root.appendingPathComponent("hud")
        let accounts = root.appendingPathComponent("accounts")
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: accounts,
                                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                                settingsURL: root.appendingPathComponent("settings.json"))
        let model = ImportCenterModel(engine: engine, hudDir: hud, userDir: accounts)
        model.rows = [.init(candidate: candidate(template: nil), state: .unadapted, note: "未适配"),
                      .init(candidate: candidate(reason: "无效来源"), state: .unsupported, note: "不支持")]
        for row in model.rows { model.toggle(row) }
        #expect(model.picked.isEmpty)
        model.toggleAll()
        #expect(model.picked.isEmpty)
        model.picked = Set(model.rows.map(\.id))
        model.importSelected()
        #expect(!model.importing)
        #expect(model.lastMessage == "请先勾选要导入的账号")
        #expect(!FileManager.default.fileExists(atPath: accounts.path))
    }
}
