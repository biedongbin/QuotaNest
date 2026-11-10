import Foundation
import Testing
@testable import QuotaNest

@Suite
struct HUDSyncTests {
    let hud = URL(fileURLWithPath: "/tmp/hud-test")

    private func custom(_ slug: String, label: String, enabled: Bool = true) -> PluginProvider {
        let dir = hud.appendingPathComponent(slug)
        HUDFixtures.writeWrapper(dir)
        return PluginProvider(slug: slug,
            manifest: ProviderManifest(name: slug, label: label, fetch: "./fetch.sh",
                                       intervalSec: nil, buckets: ["seven_day": "周"],
                                       cacheFile: nil, enabled: enabled),
            dir: dir)
    }

    /// 内置名集合由调用方动态收集 (builtin: true 的 manifest.name)
    private let builtins: Set<String> = ["CC-GLM", "Ollama"]

    @Test func envsDictBuildsEntries() {
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        let e = d["my-relay"]
        #expect(e?.label == "Relay")
        #expect(e?.source == "cache")
        #expect(e?.cache == "/tmp/hud-test/.my-relay-hud-cache.json")
        #expect(e?.fetch == "/tmp/hud-test/providers/my-relay/fetch.sh")
        #expect(e?.schemaVersion == 2)
        #expect(e?.buckets == ["seven_day": "周"])
    }

    @Test func mergePreservesBuiltinsAndDropsRemoved() {
        let existing: [String: EnvsEntry] = [
            "my-relay": EnvsEntry(label: "Relay", source: "cache", cache: "/x", buckets: [:]),
            "gone": EnvsEntry(label: "Gone", source: "cache", cache: "/y", buckets: [:]),
            // statusline 侧内置但 TokenHUD 无插件, 永不动
            "Claude-Max": EnvsEntry(label: "Max", source: "cache", cache: "/z", buckets: [:]),
        ]
        let new = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                   builtinNames: builtins)
        let merged = HUDSync.mergeEnvs(existing: existing, new: new, builtinNames: builtins)
        #expect(Set(merged.keys) == ["my-relay", "Claude-Max"]) // 外部内置 key 保留
    }

    @Test func mergeAccountEnvsAppendsAndRemoves() {
        #expect(
            HUDSync.mergeAccountEnvs(current: "CC-GLM,Ollama,OC-Go",
                                     keys: ["CC-GLM", "Ollama", "OC-Go", "my-relay"])
            == "CC-GLM,Ollama,OC-Go,my-relay")
        #expect(
            HUDSync.mergeAccountEnvs(current: "CC-GLM,my-relay,Ollama", keys: ["CC-GLM", "Ollama"])
            == "CC-GLM,Ollama")
        #expect(
            HUDSync.mergeAccountEnvs(current: nil, keys: ["CC-GLM", "my-relay"])
            == "CC-GLM,my-relay")
    }

    @Test func patchSettingsOnlyTouchesAccountEnvs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = """
        {"env": {"ACCOUNT_ENVS": "CC-GLM", "ANTHROPIC_BASE_URL": "http://x"},
         "model": "y", "theme": "dark"}
        """
        try original.write(to: tmp, atomically: true, encoding: .utf8)
        try HUDSync.patchSettings(settingsURL: tmp, accountEnvs: "CC-GLM,my-relay", statuslinePath: "/tmp/statusline.mjs")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        let env = obj?["env"] as? [String: Any]
        #expect(env?["ACCOUNT_ENVS"] as? String == "CC-GLM,my-relay")
        #expect(env?["ANTHROPIC_BASE_URL"] as? String == "http://x")
        #expect(obj?["theme"] as? String == "dark")
        // statusLine.command 缺失时补上, 确保 statusline 被调用
        let sl = obj?["statusLine"] as? [String: Any]
        #expect(sl?["command"] as? String == "node \"/tmp/statusline.mjs\"")
        #expect(sl?["type"] as? String == "command")
    }

    @Test func writeAndReadEnvsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        try HUDSync.writeEnvs(d, to: tmp)
        let back = try HUDSync.decodeEntries(Data(contentsOf: tmp))
        #expect(back["my-relay"]?.label == "Relay")
    }

    @Test func patchSettingsBacksUp() throws {
        // 已有备份不得被后续同步覆盖。
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).json")
        let backup = tmp.appendingPathExtension("bak")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: backup) }
        try #"{"env":{"ACCOUNT_ENVS":"CC-GLM"}}"#.write(to: tmp, atomically: true, encoding: .utf8)
        try HUDSync.patchSettings(settingsURL: tmp, accountEnvs: "Ollama", statuslinePath: "/tmp/s.mjs")
        let first = try Data(contentsOf: backup)
        try HUDSync.patchSettings(settingsURL: tmp, accountEnvs: "GPT", statuslinePath: "/tmp/s.mjs")
        #expect(try Data(contentsOf: backup) == first)
    }
    @Test func syncRemovesLegacyOrphansButPreservesExternalEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-orphans-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let envs = root.appendingPathComponent("envs.json")
        try #"{"env":{"ACCOUNT_ENVS":"gpt-3,zcode-start,external,Claude-Max,unregistered"},"theme":"dark","statusLine":{"command":"custom-hud"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try HUDSync.writeEnvs([
            "gpt-3": EnvsEntry(label: "codex", source: "cache",
                cache: root.appendingPathComponent(".gpt-3-usage-cache.json").path, buckets: [:]),
            "zcode-start": EnvsEntry(label: "ZCode", source: "cache",
                cache: root.appendingPathComponent(".zcode-start-usage-cache.json").path, buckets: [:]),
            "external": EnvsEntry(label: "codex", source: "cache", cache: "/external/cache.json", buckets: [:]),
            "Claude-Max": EnvsEntry(label: "Max", source: "cache",
                cache: root.appendingPathComponent(".Claude-Max-usage-cache.json").path, buckets: [:])
        ], to: envs)
        for _ in 0..<2 {
            try HUDSync.sync(plugins: [custom("current", label: "codex")], hiddenSlugs: [], disabledSlugs: [],
                             hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
            #expect((object["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "external,Claude-Max,unregistered,current")
            #expect((object["statusLine"] as? [String: Any])?["command"] as? String == "custom-hud")
            #expect(object["theme"] as? String == "dark")
            let entries = try HUDSync.decodeEntries(Data(contentsOf: envs))
            #expect(Set(entries.keys.filter { !$0.hasPrefix("_") }) == ["external", "Claude-Max", "current"])
            #expect(entries["current"]?.managedBy == "quotanest")
        }
    }

    @Test(arguments: [false, true])
    func syncPreservesForeignJSONWithoutInterpretingItsSchema(incompatibleFields: Bool) throws {
        let root = try exportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("hud")
        let envs = hud.appendingPathComponent("envs.json")
        let foreign: [String: Any] = [
            "managedBy": "another-app", "label": "Foreign", "source": "cache",
            "cache": "/foreign/cache", "buckets": [:],
            "query": incompatibleFields ? ["url": ["dynamic": true]] : ["url": "https://example.test", "headerTemplate": ""],
            "extension": ["nested": [1, 2], "enabled": true]
        ]
        let original: [String: Any] = ["foreign": foreign, "_foreignMetadata": ["version": 7], "externalValue": [1, 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: envs)
        for _ in 0..<2 {
            try HUDSync.sync(plugins: [], hiddenSlugs: [], disabledSlugs: [], hudDir: hud,
                             settingsURL: root.appendingPathComponent("settings.json"), mjsSourceDir: HUDFixtures.runtime)
            let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: envs)) as? [String: Any])
            #expect(NSDictionary(dictionary: try #require(result["foreign"] as? [String: Any])).isEqual(to: foreign))
            #expect((result["_foreignMetadata"] as? [String: Int]) == ["version": 7])
            #expect((result["externalValue"] as? [Int]) == [1, 2])
        }
    }

    @Test func syncFollowsAppOrderWhileKeepingExternalSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try #"{"env":{"ACCOUNT_ENVS":"Claude-Max,b,external,a,b,c"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        for order in [["c", "a", "b"], ["b", "c", "a"]] {
            try HUDSync.sync(plugins: order.map { custom($0, label: $0) }, hiddenSlugs: [], disabledSlugs: [],
                             hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
            #expect((object["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
                == "Claude-Max,\(order[0]),external,\(order[1]),\(order[2])")
        }
    }

    @Test func ownershipRemovesDeletedAccountsWithCustomCaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-owned-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let envs = root.appendingPathComponent("envs.json")
        try #"{"env":{"ACCOUNT_ENVS":""}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let base = custom("custom-cache", label: "Custom")
        var manifest = base.manifest
        manifest.cacheFile = "/outside/custom-cache.json"
        let plugin = PluginProvider(slug: base.slug, manifest: manifest, dir: base.dir)
        try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [], hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        var entries = try HUDSync.decodeEntries(Data(contentsOf: envs))
        #expect(entries["custom-cache"]?.managedBy == "quotanest")
        #expect(entries["custom-cache"]?.cache == root.appendingPathComponent(".custom-cache-hud-cache.json").path)
        // A foreign owner remains external even when using the legacy cache naming convention.
        entries["foreign"] = EnvsEntry(label: "Foreign", source: "cache",
            cache: root.appendingPathComponent(".foreign-usage-cache.json").path, buckets: [:], managedBy: "another-app")
        try HUDSync.writeEnvs(entries, to: envs)
        try HUDSync.sync(plugins: [], hiddenSlugs: [], disabledSlugs: [], hudDir: root, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        entries = try HUDSync.decodeEntries(Data(contentsOf: envs))
        #expect(entries["custom-cache"] == nil)
        #expect(entries["foreign"]?.managedBy == "another-app")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect((object["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String == "")
    }

    // MARK: P2-3 envs.json 版本化: 顶层 _schemaVersion 元数据, 读端过滤

    // MARK: 显式导出契约

    private func exportRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-export-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("hud"), withIntermediateDirectories: true)
        try #"{"env":{"ACCOUNT_ENVS":""}}"#.write(to: root.appendingPathComponent("settings.json"),
                                                 atomically: true, encoding: .utf8)
        return root
    }

    private func apikeyPlugin(_ root: URL, key: String) throws -> PluginProvider {
        let dir = root.appendingPathComponent("providers/fixture", isDirectory: true)
        HUDFixtures.writeWrapper(dir)
        let auth = root.appendingPathComponent("hud/.fixture-usage-auth.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "refreshApiKey": key])
            .write(to: auth, options: .atomic)
        let manifest = ProviderManifest(name: "fixture", label: "Fixture",
                                        buckets: ["seven_day": "周"], authFile: auth.path,
                                        queryUrl: "https://quota.example.test/usage",
                                        queryKeyField: "apiKey", refreshHeader: "Authorization: Bearer <key>",
                                        authMode: "apikey")
        return PluginProvider(slug: "fixture", manifest: manifest, dir: dir)
    }

    @Test func exportRefusesIncompleteRuntimeBeforeWriting() throws {
        let root = try exportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("hud")
        let settings = root.appendingPathComponent("settings.json")
        let empty = root.appendingPathComponent("empty-mjs")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let plugin = try apikeyPlugin(root, key: "k1")
        let before = try Data(contentsOf: settings)
        #expect(throws: (any Error).self) {
            try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [],
                             hudDir: hud, settingsURL: settings, mjsSourceDir: empty)
        }
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("envs.json").path))
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("providers/fixture/fetch.sh").path))
        #expect(try Data(contentsOf: settings) == before)
    }

    @Test func exportRefusesMissingWrapperBeforeWriting() throws {
        let root = try exportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("hud")
        let settings = root.appendingPathComponent("settings.json")
        let dir = root.appendingPathComponent("providers/no-wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plugin = PluginProvider(slug: "no-wrapper",
            manifest: ProviderManifest(name: "no-wrapper", label: "No Wrapper", queryUrl: "https://example.test/usage"),
            dir: dir)
        #expect(throws: (any Error).self) {
            try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [],
                             hudDir: hud, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        }
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("envs.json").path))
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("providers/no-wrapper/fetch.sh").path))
    }

    @Test func exportWritesIndependentAssetsAndClearsStaleManualKey() throws {
        let root = try exportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("hud")
        let settings = root.appendingPathComponent("settings.json")
        let plugin = try apikeyPlugin(root, key: "k1")
        try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [],
                         hudDir: hud, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        let entries = try HUDSync.decodeEntries(Data(contentsOf: hud.appendingPathComponent("envs.json")))
        let entry = try #require(entries["fixture"])
        #expect(entry.schemaVersion == 2)
        #expect(entry.cache == hud.appendingPathComponent(".fixture-hud-cache.json").path)
        #expect(entry.fetch == hud.appendingPathComponent("providers/fixture/fetch.sh").path)
        #expect(entry.query?.url == "https://quota.example.test/usage")
        #expect(entry.query?.headerTemplate == "Authorization: Bearer <key>")
        #expect(entry.credential?.keyFile == hud.appendingPathComponent(".fixture-hud-auth.json").path)
        let keyFile = try #require(entry.credential?.keyFile)
        let keyObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: keyFile))) as? [String: String])
        #expect(keyObject["key"] == "k1")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        let wrapper = try String(contentsOf: URL(fileURLWithPath: try #require(entry.fetch)), encoding: .utf8)
        #expect(wrapper.contains("$TOKENHUD_HUD_DIR/generic-usage-provider.mjs"))
        #expect(!wrapper.contains("Application Support"))
        #expect(FileManager.default.fileExists(atPath: hud.appendingPathComponent("statusline.mjs").path))
        let exported = String(decoding: try Data(contentsOf: hud.appendingPathComponent("envs.json")), as: UTF8.self)
        #expect(!exported.contains("authSourceFile"))
        #expect(!exported.contains("sourceReferenceDependencies"))
        // An explicit export after clearing the key must not leave the old snapshot reusable.
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "refreshApiKey": ""])
            .write(to: root.appendingPathComponent("hud/.fixture-usage-auth.json"), options: .atomic)
        try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [],
                         hudDir: hud, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        let cleared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: keyFile))) as? [String: String])
        #expect(cleared["key"] == "")
    }

    @Test func referenceExportNeedsNoSourceReadAndCopiesNoSecret() throws {
        let root = try exportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("hud")
        let settings = root.appendingPathComponent("settings.json")
        let dir = root.appendingPathComponent("providers/imported", isDirectory: true)
        HUDFixtures.writeWrapper(dir)
        let source = ProviderCredentialSource(file: "~/nowhere/auth.json", tokenPath: "tokens.access_token",
                                              headerPaths: ["chatgpt-account-id": "tokens.account_id"],
                                              requiredValues: ["auth_mode": "chatgpt"])
        let reference = ProviderSourceReference(source: "magpie", path: "/nonexistent/does-not-exist.json",
                                                recordId: "record-1", providerId: "codex")
        let manifest = ProviderManifest(name: "imported", label: "Imported", buckets: ["seven_day": "周"],
                                        queryUrl: "https://quota.example.test/usage", queryAuth: "header",
                                        refreshHeader: "Authorization: Bearer <key>", authMode: "auth",
                                        credentialSource: source, sourceReference: reference)
        let plugin = PluginProvider(slug: "imported", manifest: manifest, dir: dir)
        try HUDSync.sync(plugins: [plugin], hiddenSlugs: [], disabledSlugs: [],
                         hudDir: hud, settingsURL: settings, mjsSourceDir: HUDFixtures.runtime)
        let entry = try #require(try HUDSync.decodeEntries(Data(contentsOf: hud.appendingPathComponent("envs.json")))["imported"])
        #expect(entry.reference?.recordId == "record-1")
        #expect(entry.credential?.formats?.isEmpty == false)
        #expect(entry.credential?.file == nil)
        #expect(entry.credential?.keyFile == nil)
        #expect(entry.query?.authHeaderTemplate == "Authorization: Bearer <key>")
    }

    @Test func writeEnvsStampsSchemaVersion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        try HUDSync.writeEnvs(d, to: tmp)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        // 读端 decode 不炸, 且 _key 过滤后条目完整
        #expect(obj?["_schemaVersion"] as? Int == 2)
        let entries = try HUDSync.decodeEntries(Data(contentsOf: tmp))
        #expect(entries["my-relay"]?.label == "Relay")
        #expect(entries["my-relay"]?.schemaVersion == 2)
    }
}
