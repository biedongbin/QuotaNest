import Foundation

struct EnvsEntry: Codable {
    var label: String
    var source: String
    var cache: String
    var buckets: [String: String]
}

enum HUDSync {
    /// statusline ENV_REGISTRY 内置 key — envs.json 永不动它们
    static let builtinKeys: Set<String> = ["Claude-Max", "CC-GLM", "GPT", "Ollama", "OC-Go"]

    static func envsDict(plugins: [PluginProvider], hudDir: URL) -> [String: EnvsEntry] {
        var d: [String: EnvsEntry] = [:]
        for p in plugins where p.manifest.isEnabled && !builtinKeys.contains(p.manifest.name) {
            d[p.manifest.name] = EnvsEntry(
                label: p.manifest.label,
                source: "cache",
                cache: DataEngine.cachePath(for: p, hudDir: hudDir).path,
                buckets: p.manifest.buckets)
        }
        return d
    }

    /// new 全量替换自定义段; existing 里属于自定义(非内置 key)但 new 已不含的 → 删除
    static func mergeEnvs(existing: [String: EnvsEntry], new: [String: EnvsEntry]) -> [String: EnvsEntry] {
        var merged = existing.filter { builtinKeys.contains($0.key) }
        for (k, v) in new { merged[k] = v }
        return merged
    }

    /// ACCOUNT_ENVS: 原顺序保留仍然合法的 key, 新自定义 key 追加尾部
    static func mergeAccountEnvs(current: String?, keys: [String]) -> String {
        let currentList = (current ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let keep = currentList.filter { keys.contains($0) || builtinKeys.contains($0) }
        let append = keys.filter { !keep.contains($0) }
        return (keep + append).joined(separator: ",")
    }

    static func writeEnvs(_ dict: [String: EnvsEntry], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(dict).write(to: url, options: .atomic)
    }

    /// 只改 settings.json 的 env.ACCOUNT_ENVS, 其余字段原样保留 (JSONSerialization 全量)
    static func patchSettings(settingsURL: URL, accountEnvs: String) throws {
        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any]
        guard var obj else { throw NSError(domain: "HUDSync", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "settings.json 顶层非对象"]) }
        var env = obj["env"] as? [String: Any] ?? [:]
        env["ACCOUNT_ENVS"] = accountEnvs
        obj["env"] = env
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }
}
