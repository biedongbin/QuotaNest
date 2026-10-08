import Foundation
import Testing
@testable import TokenHUD

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
        // 写前备份 settings.json.bak: 手改炸文件时的救命稻草
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"env":{"ACCOUNT_ENVS":"CC-GLM"}}"#.write(to: tmp, atomically: true, encoding: .utf8)
        try HUDSync.patchSettings(settingsURL: tmp, accountEnvs: "Ollama", statuslinePath: "/tmp/s.mjs")
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathExtension("bak").path))
    }
}
