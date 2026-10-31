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

    /// 旧版固定 HUD 名称：仅用于识别并迁移本应用的历史选择键。
    static let builtinCacheFiles: [String: String] = [
        "CC-GLM": ".glm-usage-cache.json",
        "GPT": ".gpt-usage-cache.json",
        "Ollama": ".ollama-usage-cache.json",
        "OC-Go": ".oc-go-usage-cache.json",
        "Cline": ".cline-usage-cache.json",
    ]

    /// 显示名和类型名可重复；HUD 身份始终使用稳定的账号 slug。
    static func accountKey(_ plugin: PluginProvider) -> String { plugin.slug }

    static func envsDict(plugins: [PluginProvider], hudDir: URL,
                         builtinNames: Set<String>) -> [String: EnvsEntry] {
        var d: [String: EnvsEntry] = [:]
        for p in plugins where p.manifest.isEnabled {
            d[accountKey(p)] = EnvsEntry(
                label: p.manifest.fullName,
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
    /// 保留现有备份；首次写入时备份原内容，失败须反馈给调用方。
    static func patchSettings(settingsURL: URL, accountEnvs: String, statuslinePath: String) throws {
        let data = try Data(contentsOf: settingsURL)
        let out = try settingsData(data, accountEnvs: accountEnvs, statuslinePath: statuslinePath)
        let backupURL = settingsURL.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try data.write(to: backupURL, options: .withoutOverwriting)
        }
        try out.write(to: settingsURL, options: .atomic)
    }

    private static func settingsData(_ data: Data, accountEnvs: String, statuslinePath: String) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HUDSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json 顶层非对象"])
        }
        if let existing = obj["env"], !(existing is [String: Any]) {
            throw NSError(domain: "HUDSync", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json 的 env 非对象"])
        }
        var env = obj["env"] as? [String: Any] ?? [:]
        env["ACCOUNT_ENVS"] = accountEnvs
        obj["env"] = env
        if let existing = obj["statusLine"], !(existing is [String: Any]) {
            throw NSError(domain: "HUDSync", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json 的 statusLine 非对象"])
        }
        var statusLine = obj["statusLine"] as? [String: Any] ?? [:]
        if statusLine["command"] == nil {
            statusLine["command"] = "node \(statuslinePath)"
            statusLine["type"] = "command"
        }
        obj["statusLine"] = statusLine
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    /// 同步前计算两份文件，保留第三方条目；后一步失败时恢复前一步原始数据。
    static func sync(plugins: [PluginProvider], hiddenSlugs: Set<String>, disabledSlugs: Set<String>,
                     removingManagedNames: Set<String> = [], hudDir: URL, settingsURL: URL) throws {
        var managedNames = Set(plugins.map(\.slug)).union(removingManagedNames)
        let selected = plugins.filter {
            $0.manifest.isEnabled && !disabledSlugs.contains($0.slug) && !hiddenSlugs.contains($0.slug)
        }
        let settings = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: settings) as? [String: Any] else {
            throw NSError(domain: "HUDSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json 顶层非对象"])
        }
        let currentEnv = (object["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
            ?? (object["env"] as? [String: Any])?["ACCOUNT_ENV"] as? String
        let currentNames = (currentEnv ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let selectedNames = selected.map(accountKey)
        let envsURL = hudDir.appendingPathComponent("envs.json")
        let fileManager = FileManager.default
        let oldEnvs = fileManager.fileExists(atPath: envsURL.path) ? try Data(contentsOf: envsURL) : nil
        var entries: [String: EnvsEntry] = [:]
        if let oldEnvs {
            entries = try JSONDecoder().decode([String: EnvsEntry].self, from: oldEnvs)
        }
        for p in plugins {
            let ownedLegacyEntry = entries[p.manifest.name]?.cache == DataEngine.cachePath(for: p, hudDir: hudDir).path
            if builtinCacheFiles[p.manifest.name] != nil || ownedLegacyEntry {
                managedNames.insert(p.manifest.name)
            }
        }
        // 旧版按类型名选择：优先映射到缺省实例，其余同名账号各自追加。
        var aliases: [String: String] = [:]
        for p in plugins where managedNames.contains(p.manifest.name) {
            let matching = plugins.filter { $0.manifest.name == p.manifest.name }
            if matching.count == 1 || p.slug == p.manifest.template {
                aliases[p.manifest.name] = accountKey(p)
            }
        }
        var newNames: [String] = []
        for name in currentNames {
            let key = aliases[name] ?? name
            guard !managedNames.contains(name) || selectedNames.contains(key) else { continue }
            if !newNames.contains(key) { newNames.append(key) }
        }
        let names = newNames + selectedNames.filter { !newNames.contains($0) }
        let settingsOutput = try settingsData(settings, accountEnvs: names.joined(separator: ","),
                                              statuslinePath: hudDir.appendingPathComponent("statusline.mjs").path)
        for name in managedNames { entries.removeValue(forKey: name) }
        let builtin = Set(plugins.filter { $0.manifest.template != nil }.map(\.manifest.name))
        for (name, entry) in envsDict(plugins: selected, hudDir: hudDir, builtinNames: builtin) {
            entries[name] = entry
        }
        let backupURL = settingsURL.appendingPathExtension("bak")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try settings.write(to: backupURL, options: .withoutOverwriting)
        }
        try writeEnvs(entries, to: envsURL)
        do {
            try settingsOutput.write(to: settingsURL, options: .atomic)
        } catch {
            let writeError = error
            do {
                if let oldEnvs { try oldEnvs.write(to: envsURL, options: .atomic) }
                else { try fileManager.removeItem(at: envsURL) }
            } catch {
                throw NSError(domain: "HUDSync", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "写入设置失败：\(writeError.localizedDescription)；恢复额度列表也失败：\(error.localizedDescription)"])
            }
            throw NSError(domain: "HUDSync", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "写入设置失败：\(writeError.localizedDescription)；已恢复额度列表"])
        }
    }
}
