import Foundation

struct EnvsEntry: Codable {
    var label: String
    var source: String
    var cache: String
    var buckets: [String: String]

    init(label: String, source: String, cache: String, buckets: [String: String]) {
        self.label = label
        self.source = source
        self.cache = cache
        self.buckets = buckets
    }

    /// P2-3: 顶层 `_schemaVersion` 元数据 key 容错解码为空 entry, 读端过滤掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        cache = try c.decodeIfPresent(String.self, forKey: .cache) ?? ""
        buckets = try c.decodeIfPresent([String: String].self, forKey: .buckets) ?? [:]
    }
}

enum HUDSync {
    /// statusline 侧内置但 TokenHUD 无插件的 key — envs.json 永不动它们
    /// (内置供应商的 name 由 builtinNames 参数动态收集, 加新内置供应商不再改此清单)
    static let externalBuiltinKeys: Set<String> = ["Claude-Max"]

    static func envsDict(plugins: [PluginProvider], hudDir: URL,
                         builtinNames: Set<String>) -> [String: EnvsEntry] {
        var d: [String: EnvsEntry] = [:]
        for p in plugins where p.manifest.isEnabled && !builtinNames.contains(p.manifest.name) {
            d[p.manifest.name] = EnvsEntry(
                label: p.manifest.label,
                source: "cache",
                cache: DataEngine.cachePath(for: p, hudDir: hudDir).path,
                buckets: p.manifest.buckets)
        }
        return d
    }

    /// new 全量替换自定义段; existing 里属于内置/自定义(非内置 key)但 new 已不含的 → 删除
    static func mergeEnvs(existing: [String: EnvsEntry], new: [String: EnvsEntry],
                          builtinNames: Set<String>) -> [String: EnvsEntry] {
        let protected = builtinNames.union(externalBuiltinKeys)
        var merged = existing.filter { protected.contains($0.key) }
        for (k, v) in new { merged[k] = v }
        return merged
    }

    /// ACCOUNT_ENVS: 原顺序保留仍然合法的 key (仅当前启用的), 新自定义 key 追加尾部
    static func mergeAccountEnvs(current: String?, keys: [String]) -> String {
        let currentList = (current ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let keep = currentList.filter { keys.contains($0) }
        let append = keys.filter { !keep.contains($0) }
        return (keep + append).joined(separator: ",")
    }

    static func writeEnvs(_ dict: [String: EnvsEntry], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // P2-3 存储版本化: 元数据 key `_` 前缀, statusline/读端均跳过
        var out = dict.filter { !$0.key.hasPrefix("_") }
        out["_schemaVersion"] = EnvsEntry(label: "", source: "", cache: "", buckets: [:])
        try enc.encode(out).write(to: url, options: .atomic)
    }

    /// 只改 settings.json 的 env.ACCOUNT_ENVS + statusLine.command, 其余字段原样保留
    /// statusLine.command 指向 statusline.mjs, 缺失则 statusline 不被调用, HUD 不显示
    /// 写前备份 settings.json.bak (用户手改 # 注释等炸文件时的救命稻草)
    static func patchSettings(settingsURL: URL, accountEnvs: String, statuslinePath: String) throws {
        let data = try Data(contentsOf: settingsURL)
        try? data.write(to: settingsURL.appendingPathExtension("bak"), options: .atomic)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any]
        guard var obj else { throw NSError(domain: "HUDSync", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "settings.json 顶层非对象"]) }
        var env = obj["env"] as? [String: Any] ?? [:]
        env["ACCOUNT_ENVS"] = accountEnvs
        obj["env"] = env
        // statusLine.command 缺失时补上, 确保 statusline 被调用
        var statusLine = obj["statusLine"] as? [String: Any] ?? [:]
        if statusLine["command"] == nil {
            statusLine["command"] = "node \(statuslinePath)"
            statusLine["type"] = "command"
        }
        obj["statusLine"] = statusLine
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }
}
