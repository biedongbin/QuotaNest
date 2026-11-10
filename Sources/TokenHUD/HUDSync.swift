import Foundation

/// Query contract handed to the independent HUD runner (schemaVersion 2).
/// No resolved credential ever appears here; the HUD resolves the reference itself.
struct HUDQuery: Codable, Equatable {
    var url: String
    /// "\n"-joined `Name: value` lines with a `<key>` placeholder.
    var headerTemplate: String
    /// Base header lines for Auth accounts; the HUD appends credential format header paths.
    var authHeaderTemplate: String?
    /// false = headerTemplate is an explicit override; skip format header paths.
    var inheritHeaders: Bool?
    var keyField: String?
    var quotaMode: String?
    var authMode: String?
    var quotaAuthModes: [String]?
    var queryAuth: String?

    init(url: String, headerTemplate: String, authHeaderTemplate: String? = nil,
         inheritHeaders: Bool? = nil, keyField: String? = nil, quotaMode: String? = nil,
         authMode: String? = nil, quotaAuthModes: [String]? = nil, queryAuth: String? = nil) {
        self.url = url
        self.headerTemplate = headerTemplate
        self.authHeaderTemplate = authHeaderTemplate
        self.inheritHeaders = inheritHeaders
        self.keyField = keyField
        self.quotaMode = quotaMode
        self.authMode = authMode
        self.quotaAuthModes = quotaAuthModes
        self.queryAuth = queryAuth
    }
}

/// Where the HUD gets the credential for a standalone account.
/// `file` is a read-only external Auth source; `keyFile` is a 0600 export-time snapshot of a manual key.
struct HUDCredential: Codable, Equatable {
    var file: String?
    var formats: [ProviderCredentialFormat]?
    var keyFile: String?

    init(file: String? = nil, formats: [ProviderCredentialFormat]? = nil, keyFile: String? = nil) {
        self.file = file
        self.formats = formats
        self.keyFile = keyFile
    }
}

/// One exported HUD account entry. Unknown/legacy keys decode as absent.
struct EnvsEntry: Codable {
    var schemaVersion: Int?
    var label: String
    var source: String
    var cache: String
    var buckets: [String: String]
    var fetch: String?
    var query: HUDQuery?
    var reference: ProviderSourceReference?
    var credential: HUDCredential?
    /// Explicit ownership survives account deletion, including custom cache locations.
    var managedBy: String?

    init(label: String, source: String, cache: String, buckets: [String: String],
         fetch: String? = nil, query: HUDQuery? = nil, reference: ProviderSourceReference? = nil,
         credential: HUDCredential? = nil, managedBy: String? = nil, schemaVersion: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.label = label
        self.source = source
        self.cache = cache
        self.buckets = buckets
        self.fetch = fetch
        self.query = query
        self.reference = reference
        self.credential = credential
        self.managedBy = managedBy
    }

    /// 顶层 `_schemaVersion` 元数据 key 容错解码为空 entry, 读端过滤掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        cache = try c.decodeIfPresent(String.self, forKey: .cache) ?? ""
        buckets = try c.decodeIfPresent([String: String].self, forKey: .buckets) ?? [:]
        fetch = try c.decodeIfPresent(String.self, forKey: .fetch)
        query = try c.decodeIfPresent(HUDQuery.self, forKey: .query)
        reference = try c.decodeIfPresent(ProviderSourceReference.self, forKey: .reference)
        credential = try c.decodeIfPresent(HUDCredential.self, forKey: .credential)
        managedBy = try c.decodeIfPresent(String.self, forKey: .managedBy)
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

    // MARK: - HUD-owned paths (never the App's own cache/auth paths)

    static func hudCachePath(slug: String, hudDir: URL) -> URL {
        hudDir.appendingPathComponent(".\(slug)-hud-cache.json")
    }

    static func keyFilePath(slug: String, hudDir: URL) -> URL {
        hudDir.appendingPathComponent(".\(slug)-hud-auth.json")
    }

    static func fetchPath(slug: String, hudDir: URL) -> URL {
        hudDir.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("fetch.sh")
    }

    /// The bundled mjs directory that ships beside the App resources.
    static func bundledMjsDir(bundleProvidersDir: URL?) -> URL? {
        bundleProvidersDir?.deletingLastPathComponent().appendingPathComponent("mjs", isDirectory: true)
    }

    // MARK: - Entry projection

    static func entries(plugins: [PluginProvider], hudDir: URL) -> [String: EnvsEntry] {
        var d: [String: EnvsEntry] = [:]
        for p in plugins where p.manifest.isEnabled {
            d[accountKey(p)] = entry(for: p, hudDir: hudDir)
        }
        return d
    }

    /// Backwards-compatible name used by existing call sites/tests.
    static func envsDict(plugins: [PluginProvider], hudDir: URL,
                         builtinNames: Set<String>) -> [String: EnvsEntry] {
        entries(plugins: plugins, hudDir: hudDir)
    }

    /// Builds the public projection only: no credential resolution, no network, no writes.
    static func entry(for p: PluginProvider, hudDir: URL) -> EnvsEntry {
        let authFile = p.manifest.authFile.map(PluginGenerator.expandPath)
            ?? hudDir.appendingPathComponent(".\(p.slug)-usage-auth.json")
        let config = ProviderConfigStore.read(authFile: authFile, manifest: p.manifest)
        let apiOnly = p.manifest.quotaMode == "none"
            || (p.manifest.quotaMode != nil && config.quotaMode == "none")
        let authMode = config.authMode
        // The quota address is the declared query address, never derived from a model base URL.
        let url = config.inheritQueryURL ?? config.queryUrl
        let baseAuthHeader = p.manifest.authCallHeader ?? "Authorization: Bearer <key>"
        let overrideHeader = config.inheritQueryHeader
        let apiHeader = overrideHeader ?? p.manifest.refreshHeader ?? "Authorization: Bearer <key>"
        let authHeader = overrideHeader ?? baseAuthHeader
        // Imported entries: the runtime takes auth/apikey from the source record, which the App
        // must not read at export time. Export BOTH templates so the HUD can pick per record.
        let isReference = config.sourceReference != nil
        let query = HUDQuery(url: url,
                             headerTemplate: (isReference || authMode != "auth") ? apiHeader : authHeader,
                             authHeaderTemplate: (isReference || authMode == "auth") ? authHeader : nil,
                             inheritHeaders: overrideHeader == nil,
                             keyField: p.manifest.queryKeyField,
                             quotaMode: config.quotaMode,
                             authMode: isReference ? nil : authMode,
                             quotaAuthModes: p.manifest.quotaAuthModes,
                             queryAuth: p.manifest.queryAuth)
        let formats = p.manifest.credentialSource.map(ProviderAuthentication.formats)
        let resolvedFormats = (formats?.isEmpty == false) ? formats : nil
        let reference = config.sourceReference
        let credential: HUDCredential?
        if reference != nil {
            // Metadata only: the HUD applies these formats to the record it reads itself.
            credential = resolvedFormats.map { HUDCredential(formats: $0) }
        } else if authMode == "auth" {
            credential = HUDCredential(file: ProviderAuthentication.credentialFileURL(for: config)?.path,
                                       formats: resolvedFormats)
        } else {
            credential = HUDCredential(keyFile: keyFilePath(slug: p.slug, hudDir: hudDir).path)
        }
        return EnvsEntry(label: p.manifest.fullName,
                         source: apiOnly ? "api" : "cache",
                         cache: hudCachePath(slug: p.slug, hudDir: hudDir).path,
                         buckets: p.manifest.buckets,
                         fetch: apiOnly ? nil : fetchPath(slug: p.slug, hudDir: hudDir).path,
                         query: query, reference: reference, credential: credential,
                         managedBy: "quotanest", schemaVersion: 2)
    }

    /// Manual API-key snapshot for the HUD (explicit export-time copy; never for imported sources).
    static func manualKey(for p: PluginProvider, hudDir: URL) -> String? {
        let authFile = p.manifest.authFile.map(PluginGenerator.expandPath)
            ?? hudDir.appendingPathComponent(".\(p.slug)-usage-auth.json")
        let config = ProviderConfigStore.read(authFile: authFile, manifest: p.manifest)
        guard config.sourceReference == nil, config.authMode != "auth" else { return nil }
        let key = config.refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: - Envs file

    /// Tolerant decode: top-level `_schemaVersion` is a number and legacy files used an object.
    static func decodeEntries(_ data: Data) throws -> [String: EnvsEntry] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HUDSync", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "envs.json 顶层非对象"])
        }
        let decoder = JSONDecoder()
        var out: [String: EnvsEntry] = [:]
        for (key, value) in object where !key.hasPrefix("_") && value is [String: Any] {
            let entryData = try JSONSerialization.data(withJSONObject: value)
            out[key] = try decoder.decode(EnvsEntry.self, from: entryData)
        }
        return out
    }

    static func writeEnvs(_ dict: [String: EnvsEntry], to url: URL) throws {
        var out: [String: EnvsEntry] = [:]
        for (key, entry) in dict where !key.hasPrefix("_") {
            var stamped = entry
            // Only App-owned exports speak schema v2. Foreign entries keep whatever they declared.
            if stamped.managedBy == "quotanest" {
                stamped.schemaVersion = 2
            }
            out[key] = stamped
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try enc.encode(out)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw NSError(domain: "HUDSync", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "envs.json 编码失败"])
        }
        object["_schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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
            statusLine["command"] = "node \"\(statuslinePath)\""
            statusLine["type"] = "command"
        }
        obj["statusLine"] = statusLine
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Explicit export (the only code path allowed to write HUD files)

    /// 同步前计算两份文件，保留第三方条目；后一步失败时恢复前一步原始数据。
    /// Only the explicit "写入 Claude Code HUD" action calls this. Startup, source sync,
    /// cache writes, toggles, ordering and deletion never do.
    static func sync(plugins: [PluginProvider], hiddenSlugs: Set<String>, disabledSlugs: Set<String>,
                     removingManagedNames: Set<String> = [], hudDir: URL, settingsURL: URL,
                     mjsSourceDir: URL? = nil) throws {
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
        // Foreign entries retain their own schema and extension fields. Only inspect
        // ownership metadata; never round-trip them through our Codable contract.
        var entries: [String: Any] = [:]
        if let oldEnvs {
            guard let raw = try JSONSerialization.jsonObject(with: oldEnvs) as? [String: Any] else {
                throw exportFailure("envs.json 顶层非对象")
            }
            entries = raw
        }
        for p in plugins {
            let legacy = entries[p.manifest.name] as? [String: Any]
            let ownedLegacyEntry = legacy?["cache"] as? String == DataEngine.cachePath(for: p, hudDir: hudDir).path
            if builtinCacheFiles[p.manifest.name] != nil || ownedLegacyEntry {
                managedNames.insert(p.manifest.name)
            }
        }
        // Export ownership remains identifiable even after its provider directory is gone.
        // Legacy exports used a slug-specific cache in hudDir; never infer ownership from label alone.
        for (key, value) in entries where !key.hasPrefix("_") && !externalBuiltinKeys.contains(key) {
            guard let entry = value as? [String: Any] else { continue }
            let legacyCache = hudDir.appendingPathComponent(".\(key)-usage-cache.json").standardizedFileURL.path
            let hudCache = hudCachePath(slug: key, hudDir: hudDir).standardizedFileURL.path
            let cache = entry["cache"] as? String
            let source = entry["source"] as? String
            let legacyOwned = entry["managedBy"] == nil && !key.contains("/")
                && (cache == legacyCache || cache == hudCache)
                && (source == "cache" || source == "api")
            if entry["managedBy"] as? String == "quotanest" || legacyOwned { managedNames.insert(key) }
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
        var orderedAccounts = selectedNames.makeIterator()
        var seenCurrent: Set<String> = []
        for name in currentNames {
            let key = aliases[name] ?? name
            guard seenCurrent.insert(key).inserted else { continue }
            if managedNames.contains(name) || managedNames.contains(key) {
                // Replace surviving managed slots in the App's order; keep external entries in place.
                guard selectedNames.contains(key), let next = orderedAccounts.next() else { continue }
                newNames.append(next)
            } else {
                newNames.append(key)
            }
        }
        let names = newNames + selectedNames.filter { !newNames.contains($0) }
        let settingsOutput = try settingsData(settings, accountEnvs: names.joined(separator: ","),
                                              statuslinePath: hudDir.appendingPathComponent("statusline.mjs").path)
        for name in managedNames { entries.removeValue(forKey: name) }
        var fresh = HUDSync.entries(plugins: selected, hudDir: hudDir)
        let staged = try stageAssets(plugins: selected, hudDir: hudDir, mjsSourceDir: mjsSourceDir,
                                     entries: &fresh)
        let encoder = JSONEncoder()
        for (name, entry) in fresh {
            entries[name] = try JSONSerialization.jsonObject(with: encoder.encode(entry))
        }
        entries["_schemaVersion"] = 2
        let envsOutput = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let backupURL = settingsURL.appendingPathExtension("bak")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try settings.write(to: backupURL, options: .withoutOverwriting)
        }
        // Stage every target before touching the HUD: a validation failure must not half-write it.
        var restore: [URL: Data?] = [:]
        for target in staged.map(\.url) + [envsURL] {
            restore[target] = fileManager.fileExists(atPath: target.path)
                ? (try? Data(contentsOf: target)) ?? Data() : nil
        }
        for asset in staged { try writeAsset(asset) }
        do {
            try envsOutput.write(to: envsURL, options: .atomic)
            try settingsOutput.write(to: settingsURL, options: .atomic)
        } catch {
            let commitError = error
            var rollbackIssues: [String] = []
            for (target, previous) in restore {
                do {
                    if let previous { try previous.write(to: target, options: .atomic) }
                    else if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                } catch { rollbackIssues.append(target.lastPathComponent) }
            }
            if rollbackIssues.isEmpty {
                throw NSError(domain: "HUDSync", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "写入 HUD 失败：\(commitError.localizedDescription)；已恢复到导出前的文件"])
            }
            throw NSError(domain: "HUDSync", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "写入 HUD 失败：\(commitError.localizedDescription)；部分文件未能恢复：\(rollbackIssues.joined(separator: "、"))"])
        }
    }

    private struct StagedAsset {
        let url: URL
        let data: Data
        let permissions: Int?
    }

    private static let requiredRuntimeScripts = ["statusline.mjs", "ref-usage-provider.mjs",
                                                 "source-readers.mjs", "hud-runtime.mjs"]

    private static func exportFailure(_ message: String) -> NSError {
        NSError(domain: "HUDSync", code: 7, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Validates the HUD runtime and every wrapper, then stages all bytes without writing.
    /// Nothing is mutated until the whole export is known to be complete.
    private static func stageAssets(plugins: [PluginProvider], hudDir: URL, mjsSourceDir: URL?,
                                    entries: inout [String: EnvsEntry]) throws -> [StagedAsset] {
        let fm = FileManager.default
        guard let mjsSourceDir else {
            throw exportFailure("缺少 HUD 运行时脚本目录，无法导出；请重新安装 QuotaNest")
        }
        guard let files = try? fm.contentsOfDirectory(at: mjsSourceDir, includingPropertiesForKeys: nil) else {
            throw exportFailure("无法读取 HUD 运行时脚本目录 \(mjsSourceDir.path)；请重新安装 QuotaNest")
        }
        let mjsFiles = files.filter { $0.pathExtension == "mjs" }
        let available = Set(mjsFiles.map(\.lastPathComponent))
        let missing = requiredRuntimeScripts.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw exportFailure("HUD 运行时缺少脚本：\(missing.joined(separator: "、"))；请重新安装 QuotaNest")
        }
        var staged: [StagedAsset] = []
        for file in mjsFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file) else {
                throw exportFailure("HUD 运行时脚本无法读取：\(file.lastPathComponent)")
            }
            staged.append(StagedAsset(url: hudDir.appendingPathComponent(file.lastPathComponent),
                                      data: data, permissions: nil))
        }
        for p in plugins {
            guard var entry = entries[accountKey(p)] else { continue }
            if entry.source == "cache" {
                let source = p.dir.appendingPathComponent(p.manifest.fetch)
                guard let raw = try? String(contentsOf: source, encoding: .utf8), !raw.isEmpty else {
                    throw exportFailure("账号 \(p.manifest.fullName) 缺少可导出的查询脚本：\(source.path)")
                }
                let script = raw.replacingOccurrences(of: "{SLUG}", with: p.slug)
                if let adapter = referencedRuntimeScript(script), !available.contains(adapter) {
                    throw exportFailure("账号 \(p.manifest.fullName) 需要的查询适配器 \(adapter) 不在 HUD 运行时中；请重新安装 QuotaNest")
                }
                let target = fetchPath(slug: p.slug, hudDir: hudDir)
                entry.fetch = target.path
                staged.append(StagedAsset(url: target, data: Data(script.utf8), permissions: 0o755))
            }
            if let keyFile = entry.credential?.keyFile {
                // An explicitly empty key is written as {"key": ""} so a previous snapshot cannot be reused.
                let key = manualKey(for: p, hudDir: hudDir) ?? ""
                let data = try JSONSerialization.data(withJSONObject: ["key": key], options: [.sortedKeys])
                staged.append(StagedAsset(url: URL(fileURLWithPath: keyFile), data: data, permissions: 0o600))
            }
            entries[accountKey(p)] = entry
        }
        return staged
    }

    /// Runtime adapter referenced by a provider wrapper (`$TOKENHUD_HUD_DIR/<name>.mjs` or `$HUD_DIR/<name>.mjs`).
    private static func referencedRuntimeScript(_ script: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\$(?:TOKENHUD_HUD_DIR|HUD_DIR)/([A-Za-z0-9._-]+\.mjs)"#) else { return nil }
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              let captured = Range(match.range(at: 1), in: script) else { return nil }
        return String(script[captured])
    }

    private static func writeAsset(_ asset: StagedAsset) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: asset.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try asset.data.write(to: asset.url, options: .atomic)
        if let permissions = asset.permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: asset.url.path)
        }
    }

    /// Provider wrapper with `{SLUG}` substituted. It resolves everything from `$TOKENHUD_HUD_DIR`,
    /// so the HUD copy has no App-bundle or Application Support dependency.
    static func fetchScript(for p: PluginProvider) -> String {
        let path = p.dir.appendingPathComponent(p.manifest.fetch)
        guard let raw = try? String(contentsOf: path, encoding: .utf8), !raw.isEmpty else { return "" }
        return raw.replacingOccurrences(of: "{SLUG}", with: p.slug)
    }
}
