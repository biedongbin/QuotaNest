import Foundation
import Testing
@testable import QuotaNest

@Suite
struct HUDSyncTests {
    let hud = URL(fileURLWithPath: "/tmp/hud-test")

    private func custom(_ slug: String, label: String, enabled: Bool = true) -> PluginProvider {
        PluginProvider(slug: slug,
            manifest: ProviderManifest(name: slug, label: label, fetch: "./fetch.sh",
                                       intervalSec: nil, buckets: ["seven_day": "周"],
                                       cacheFile: nil, enabled: enabled),
            dir: hud.appendingPathComponent(slug))
    }

    /// 内置名集合由调用方动态收集 (builtin: true 的 manifest.name)
    private let builtins: Set<String> = ["CC-GLM", "Ollama"]

    @Test func envsDictBuildsEntries() {
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        let e = d["my-relay"]
        #expect(e?.label == "Relay")
        #expect(e?.source == "cache")
        #expect(e?.cache == "/tmp/hud-test/.my-relay-usage-cache.json")
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
        #expect(sl?["command"] as? String == "node /tmp/statusline.mjs")
        #expect(sl?["type"] as? String == "command")
    }

    @Test func writeAndReadEnvsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        try HUDSync.writeEnvs(d, to: tmp)
        let back = try JSONDecoder().decode([String: EnvsEntry].self, from: Data(contentsOf: tmp))
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
    // MARK: P2-3 envs.json 版本化: 顶层 _schemaVersion 元数据, 读端过滤

    @Test func writeEnvsStampsSchemaVersion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud,
                                 builtinNames: builtins)
        try HUDSync.writeEnvs(d, to: tmp)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        #expect(obj?["_schemaVersion"] != nil)
        // 读端 decode 不炸, 且 _key 过滤后条目完整
        let back = try JSONDecoder().decode([String: EnvsEntry].self, from: Data(contentsOf: tmp))
        let entries = back.filter { !$0.key.hasPrefix("_") }
        #expect(entries["my-relay"]?.label == "Relay")
    }
}
