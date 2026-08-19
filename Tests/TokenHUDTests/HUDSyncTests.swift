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

    @Test func envsDictBuildsEntries() {
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud)
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
        ]
        let new = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud)
        let merged = HUDSync.mergeEnvs(existing: existing, new: new)
        #expect(Set(merged.keys) == ["my-relay"])
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
        try HUDSync.patchSettings(settingsURL: tmp, accountEnvs: "CC-GLM,my-relay")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        let env = obj?["env"] as? [String: Any]
        #expect(env?["ACCOUNT_ENVS"] as? String == "CC-GLM,my-relay")
        #expect(env?["ANTHROPIC_BASE_URL"] as? String == "http://x")
        #expect(obj?["theme"] as? String == "dark")
    }

    @Test func writeAndReadEnvsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = HUDSync.envsDict(plugins: [custom("my-relay", label: "Relay")], hudDir: hud)
        try HUDSync.writeEnvs(d, to: tmp)
        let back = try JSONDecoder().decode([String: EnvsEntry].self, from: Data(contentsOf: tmp))
        #expect(back["my-relay"]?.label == "Relay")
    }
}
