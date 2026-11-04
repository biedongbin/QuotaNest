import Foundation
import CryptoKit

/// A preview carries source identity and adapter metadata, never source credentials.
struct ImportCandidate: Identifiable {
    let id = UUID()
    let source: String
    let name: String
    let template: String?
    // Retained for source compatibility with older callers; production scans always leave it empty.
    let apiKey: String
    let baseURL: String
    let proto: String
    var note: String
    var exists = false
    var unsupportedReason: String? = nil
    var enabled = true
    var slugHint: String? = nil
    var sourceAccount: String = ""
    var sourceRecordId: String = ""
    var sourceReference: ProviderSourceReference? = nil
    var sourceAuthMode: String = "apikey"

    var authLabel: String { sourceAuthMode == "auth" || note.lowercased().contains("oauth") ? "Auth" : "API Key" }
    var origin: String {
        if source == "cc-switch", let collection = sourceReference?.collection {
            return "\(source):\(collection):\(sourceRecordId)"
        }
        return "\(source):\(sourceRecordId)"
    }
}

enum ProviderImporter {
    static let sqlite = "/usr/bin/sqlite3"

    /// Identity aliases only. Wire protocols and credentials remain manifest driven.
    static let sourceAliases = [
        "codex": "gpt", "claude": "claude-code", "copilot": "github-copilot",
        "github": "github-copilot", "clinepass": "cline", "cline-pass": "cline",
        "glm-cn": "glm", "glm-international": "zai-coding", "z-ai": "zai-coding",
        "zai": "zai-coding", "gemini": "gemini-cli", "grok": "grok-cli",
        "commandcode-plan": "commandcode", "mimo-app": "xiaomi-mimo-desktop"
    ]

    static func bundledTemplates() -> [PluginProvider] {
        Bundle.module.resourceURL.map { ProviderRegistry.scan(dir: $0.appendingPathComponent("providers")) } ?? []
    }

    static func magpieRoot(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let xdg = environment["XDG_CONFIG_HOME"], (xdg as NSString).isAbsolutePath {
            return URL(fileURLWithPath: xdg).appendingPathComponent("magpie").path
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/magpie").path
    }

    static func from9Router(home: String, templates supplied: [PluginProvider]? = nil) -> [ImportCandidate] {
        let templates = supplied ?? bundledTemplates()
        let db = home + "/.9router/db/data.sqlite"
        let rows = query(db, "SELECT id, provider, authType, name, isActive, data FROM providerConnections")
        var counts: [String: Int] = [:]
        return rows.compactMap { row in
            guard let provider = row["provider"] as? String,
                  let id = row["id"] as? String, !id.isEmpty else { return nil }
            let object = (row["data"] as? String).flatMap { json(Data($0.utf8)) } ?? [:]
            let mode = row["authType"] as? String == "oauth" ? "auth" : "apikey"
            let specific = object["providerSpecificData"] as? [String: Any] ?? [:]
            let base = specific["baseUrl"] as? String ?? object["baseUrl"] as? String ?? ""
            let proto = provider.hasPrefix("anthropic-compatible") ? "anthropic" : "openai"
            let reference = ProviderSourceReference(source: "9router", path: db, recordId: id,
                                                    providerId: provider, collection: "providerConnections")
            let label = row["name"] as? String ?? provider
            let family = familyName(provider)
            counts[family, default: 0] += 1
            let name = isAccountId(label) ? "\(family) 账号 \(counts[family, default: 1])" : "\(family) · \(label)"
            return candidate(reference: reference, provider: provider, label: name, rawAccount: label,
                             mode: mode, base: base, proto: proto, templates: templates,
                             enabled: (row["isActive"] as? Int ?? 1) != 0,
                             allowGeneric: provider.hasPrefix("openai-compatible") || provider.hasPrefix("anthropic-compatible"))
        }
    }

    static func fromCCSwitch(home: String, templates supplied: [PluginProvider]? = nil) -> [ImportCandidate] {
        let templates = supplied ?? bundledTemplates()
        let db = home + "/.cc-switch/cc-switch.db"
        return query(db, "SELECT id, app_type, name, settings_config FROM providers").compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let app = row["app_type"] as? String else { return nil }
            let object = (row["settings_config"] as? String).flatMap { json(Data($0.utf8)) } ?? [:]
            let env = object["env"] as? [String: Any] ?? [:]
            let base = env["ANTHROPIC_BASE_URL"] as? String ?? object["base_url"] as? String ?? ""
            let mode = app == "claude" ? "apikey" : "auth"
            let reference = ProviderSourceReference(source: "cc-switch", path: db, recordId: id,
                                                    providerId: app, collection: app)
            let label = row["name"] as? String ?? app
            // app_type is a schema namespace, not proof that a relay is the official vendor.
            let identity = mode == "auth" ? app : ""
            return candidate(reference: reference, provider: identity, label: label, rawAccount: label,
                             mode: mode, base: base, proto: app == "claude" ? "anthropic" : "responses",
                             templates: templates, allowGeneric: app == "claude")
        }
    }

    static func fromCPAMP(home: String, templates supplied: [PluginProvider]? = nil) -> [ImportCandidate] {
        let templates = supplied ?? bundledTemplates()
        let dir = home + "/.cli-proxy-api"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.sorted().filter { $0.hasSuffix(".json") }.compactMap { file in
            let path = dir + "/" + file
            guard let bytes = FileManager.default.contents(atPath: path), let object = json(bytes),
                  let type = object["type"] as? String else { return nil }
            let label = object["label"] as? String ?? object["email"] as? String ?? String(file.dropLast(5))
            let mode = (object["api_key"] as? String)?.isEmpty == false ? "apikey" : "auth"
            let reference = ProviderSourceReference(source: "cpamp", path: path, recordId: file,
                                                    providerId: type, collection: "auth-files")
            return candidate(reference: reference, provider: type, label: label, rawAccount: label,
                             mode: mode, base: object["base_url"] as? String ?? "", proto: "responses",
                             templates: templates, enabled: object["disabled"] as? Bool != true)
        }
    }

    static func fromMagpie(home: String, sourceDirectory: String? = nil,
                           templates supplied: [PluginProvider]? = nil,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> [ImportCandidate] {
        let templates = supplied ?? bundledTemplates()
        let root = sourceDirectory ?? magpieRoot(home: home, environment: environment)
        let path = URL(fileURLWithPath: root).appendingPathComponent("providers.json").path
        let providers = readObject(path)?["providers"] as? [[String: Any]] ?? []
        var result: [ImportCandidate] = []
        for provider in providers {
            guard let id = provider["id"] as? String, !id.isEmpty else { continue }
            // Subscription settings may have no endpoints; their credentials are handled below.
            let endpoints = ["chat", "responses", "anthropic", "gemini"].compactMap { provider[$0] as? String }
            guard !endpoints.isEmpty else { continue }
            let keyProtocol = provider["keyProtocol"] as? String ?? ""
            let selected = keyProtocol.isEmpty ? (provider["baseAPI"] as? String ?? "")
                : (keyProtocol == "openai" ? "chat" : keyProtocol)
            let endpoint = ([selected] + ["chat", "responses", "anthropic", "gemini"]).first {
                (provider[$0] as? String)?.isEmpty == false
            } ?? ""
            let proto = endpoint == "chat" ? "openai" : endpoint
            let base = provider[endpoint] as? String ?? ""
            let identity = provider["preset"] as? String ?? provider["catalog"] as? String ?? id
            let label = provider["name"] as? String ?? id
            let enabled = provider["off"] as? Bool != true && provider["hidden"] as? Bool != true
            if (provider["key"] as? String)?.isEmpty == false {
                let reference = ProviderSourceReference(source: "magpie", path: path, recordId: id,
                                                        providerId: id, collection: "providers")
                var primary = candidate(reference: reference, provider: identity, label: label,
                                        rawAccount: provider["keyName"] as? String ?? "", mode: "apikey",
                                        base: base, proto: proto, templates: templates, enabled: enabled,
                                        allowGeneric: true)
                primary.note += " · 引用当前主 Key，随源切换或更新"
                result.append(primary)
            }
            var seenKeys = Set<String>()
            for key in provider["keys"] as? [[String: Any]] ?? [] {
                guard let secret = key["key"] as? String, !secret.isEmpty else { continue }
                let fingerprint = SHA256.hash(data: Data(secret.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
                guard seenKeys.insert(fingerprint).inserted else { continue }
                let reference = ProviderSourceReference(source: "magpie", path: path, recordId: id,
                                                        providerId: id, collection: "providers:key:" + fingerprint)
                let account = key["name"] as? String ?? fingerprint
                var extra = candidate(reference: reference, provider: identity, label: label + " · " + maskIfAccount(account),
                                        rawAccount: account, mode: "apikey", base: base,
                                        proto: key["protocol"] as? String ?? proto, templates: templates,
                                        enabled: enabled && key["off"] as? Bool != true, allowGeneric: true)
                extra.note += " · 引用指定来源 Key（\(fingerprint)）"
                result.append(extra)
            }
        }
        let authPath = URL(fileURLWithPath: root).appendingPathComponent("plugin-auth.json").path
        let auth = readObject(authPath) ?? [:]
        let cachePath = URL(fileURLWithPath: root).appendingPathComponent("plugin-providers.json")
        let cache = (try? Data(contentsOf: cachePath)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]]
        } ?? []
        for key in auth.keys.sorted() {
            guard let object = auth[key] as? [String: Any] else { continue }
            let credentialID = String(key.split(separator: "#", maxSplits: 1).first ?? "")
            let listed = cache.filter { $0["id"] as? String == credentialID }
            let cacheEntry = listed.count == 1 ? listed.first : nil
            // Resolve only IDs evidenced by stored Magpie records; never invent an -plugin suffix.
            let actualIDs = providers.compactMap { item -> String? in
                guard let id = item["id"] as? String, id == credentialID || id == credentialID + "-plugin",
                      !["chat", "responses", "anthropic", "gemini"].contains(where: { (item[$0] as? String)?.isEmpty == false }) else { return nil }
                return id
            }
            let actualID = actualIDs.count == 1 ? actualIDs[0] : credentialID
            let reference = ProviderSourceReference(source: "magpie", path: authPath, recordId: key,
                                                    providerId: actualID, collection: "plugin-auth",
                                                    credentialProviderId: credentialID)
            let label = cacheEntry?["name"] as? String ?? credentialID
            var c = candidate(reference: reference, provider: credentialID, label: label,
                              rawAccount: object["accountId"] as? String ?? object["email"] as? String ?? "",
                              mode: object["type"] as? String == "api" ? "apikey" : "auth",
                              base: "", proto: "", templates: templates)
            if cacheEntry == nil || actualIDs.count != 1 {
                c.unsupportedReason = "Magpie 插件缓存与原始供应商 ID 无法唯一对应；请在 Magpie 中确认账号"
            }
            result.append(c)
        }
        let loginsPath = URL(fileURLWithPath: root).appendingPathComponent("logins.json").path
        let logins = (try? Data(contentsOf: URL(fileURLWithPath: loginsPath))).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]]
        } ?? []
        for login in logins {
            guard let agent = login["agent"] as? String else { continue }
            let user = login["user"] as? String ?? ""
            let recordID = login["id"] as? String ?? ""
            result.append(ImportCandidate(source: "magpie", name: familyName(agent) + " · " + maskIfAccount(user),
                template: nil, apiKey: "", baseURL: "", proto: "", note: agent + " / OAuth",
                unsupportedReason: "原生账号的活动凭据可能由 CLI 或 Keychain 持有；当前不支持安全的只读账号解析",
                enabled: login["on"] as? Bool ?? false, slugHint: PluginGenerator.slugify(agent),
                sourceAccount: maskAccount(user), sourceRecordId: recordID,
                sourceReference: ProviderSourceReference(source: "magpie", path: loginsPath, recordId: recordID,
                    providerId: agent, collection: "logins"), sourceAuthMode: "auth"))
        }
        return result
    }

    private static func candidate(reference: ProviderSourceReference, provider: String, label: String,
                                  rawAccount: String, mode: String, base: String, proto: String,
                                  templates: [PluginProvider], enabled: Bool = true,
                                  allowGeneric: Bool = false) -> ImportCandidate {
        let template = matchingTemplate(provider: provider, base: base, templates: templates)
        var effectiveBase = base
        var effectiveProtocol = proto
        var reason: String?
        var initializedReference = reference
        if let template {
            let manifest = template.manifest
            if !manifest.supportsQuota || (manifest.quotaAuthModes.map { !$0.contains(mode) } ?? false)
                || (["jwt", "cookie"].contains(manifest.queryAuth ?? "") && manifest.inheritQueryUrl == nil) {
                reason = "该类型未提供继承当前基础认证的额度适配，本轮不支持导入"
            } else if mode == "auth", manifest.credentialSource == nil {
                reason = "该类型未声明 Auth 来源格式"
            }
        } else if mode == "auth" {
            reason = "该来源没有匹配的 Auth 类型与授权格式"
        } else if !allowGeneric {
            reason = "该来源没有对应的供应商类型；不会自动转换为通用供应商"
        }
        do {
            let record = try ImportedSource.read(reference)
            effectiveBase = record.baseURL
            effectiveProtocol = record.protocolName
            if reason == nil && template == nil && (!validEndpoint(effectiveBase)
                || !["openai", "chat", "responses", "anthropic"].contains(effectiveProtocol)) {
                reason = "源里缺少受支持的接口地址或调用协议"
            }
            if record.authMode == "auth", let source = template?.manifest.credentialSource,
               !formats(source).contains(where: { accepts($0, object: record.object) }) {
                reason = "来源授权结构未匹配该类型声明的 Auth 格式"
            }
            if record.authMode == "apikey", record.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "源里这条没有可用的 API Key"
            }
            if reason == nil {
                initializedReference = SourceSynchronizer.register(reference, record: record, template: template)
            }
        } catch { reason = error.localizedDescription }
        let name = maskIfAccount(label)
        return ImportCandidate(source: reference.source, name: name, template: template?.slug,
            apiKey: "", baseURL: template == nil ? effectiveBase : "", proto: effectiveProtocol,
            note: "\(reference.providerId ?? provider) / \(mode == "auth" ? "OAuth" : "apikey")",
            unsupportedReason: reason, enabled: enabled, slugHint: PluginGenerator.slugify(template?.slug ?? provider),
            sourceAccount: isAccountId(rawAccount) ? maskAccount(rawAccount) : "",
            sourceRecordId: reference.recordId, sourceReference: initializedReference, sourceAuthMode: mode)
    }

    static func matchingTemplate(provider: String, base: String, templates: [PluginProvider]) -> PluginProvider? {
        if let exact = templates.first(where: { $0.slug == provider }) { return exact }
        if let alias = sourceAliases[provider], let found = templates.first(where: { $0.slug == alias }) { return found }
        let declared = templates.filter { template in
            guard let source = template.manifest.credentialSource else { return false }
            return formats(source).contains { format in
                (format.requiredValues ?? [:]).contains { ["provider", "type"].contains($0.key) && $0.value == provider }
            }
        }
        if declared.count == 1 { return declared[0] }
        guard let endpoint = canonicalEndpoint(base) else { return nil }
        let endpoints = templates.filter { template in
            let m = template.manifest
            return [m.refreshUrl, m.authCallUrl].compactMap { $0 }.contains { canonicalEndpoint($0) == endpoint }
        }
        return endpoints.count == 1 ? endpoints[0] : nil
    }

    private static func canonicalEndpoint(_ value: String) -> String? {
        guard var url = URLComponents(string: value), let host = url.host,
              url.user == nil, ["http", "https"].contains(url.scheme ?? "") else { return nil }
        url.host = host.lowercased()
        url.query = nil; url.fragment = nil
        var path = url.path
        for suffix in ["/chat/completions", "/responses", "/messages", "/models"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" { path = "" }
        else if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
        url.path = path.isEmpty ? "" : "/" + path
        return url.string
    }

    private static func validEndpoint(_ value: String) -> Bool { canonicalEndpoint(value) != nil }

    private static func formats(_ source: ProviderCredentialSource) -> [ProviderCredentialFormat] {
        [ProviderCredentialFormat(tokenPath: source.tokenPath, headerPaths: source.headerPaths,
            requiredValues: source.requiredValues, contextPaths: source.contextPaths)] + (source.alternatives ?? [])
    }

    private static func accepts(_ format: ProviderCredentialFormat, object: [String: Any]) -> Bool {
        func string(_ path: String) -> String? {
            let keys = path.hasPrefix("/")
                ? path.dropFirst().split(separator: "/").map { String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
                : path.split(separator: ".").map(String.init)
            return keys.reduce(object as Any?) { ($0 as? [String: Any])?[$1] } as? String
        }
        return (format.requiredValues ?? [:]).allSatisfy { string($0.key) == $0.value }
            && string(format.tokenPath)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func isAccountId(_ s: String) -> Bool {
        if s.contains("@") { return true }
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if s.range(of: uuid, options: .regularExpression) != nil { return true }
        return (s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(\.count).max() ?? 0) >= 16
    }

    static func maskAccount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        if s.filter({ $0 == "@" }).count == 1, let at = s.firstIndex(of: "@") {
            let local = s[s.startIndex..<at]
            let parts = s[s.index(after: at)...].split(separator: ".")
            return "\(local.prefix(2))***@\(parts.first.map { String($0.prefix(1)) } ?? "*")***.\(parts.count > 1 ? String(parts.last ?? "com") : "com")"
        }
        return String(s.prefix(2)) + "***"
    }

    private static func maskIfAccount(_ value: String) -> String { isAccountId(value) ? maskAccount(value) : value }
    private static func familyName(_ value: String) -> String {
        if value.hasPrefix("anthropic-compatible") { return "Anthropic 兼容" }
        if value.hasPrefix("openai-compatible") { return "OpenAI 兼容" }
        return value == "glm" ? "GLM" : value.prefix(1).uppercased() + value.dropFirst()
    }

    /// Stage only local metadata. Source credentials are revalidated and never written locally.
    @discardableResult
    static func apply(_ c: ImportCandidate, templates: [PluginProvider], userDir: URL, hudDir: URL) throws -> String {
        guard c.unsupportedReason == nil, let reference = c.sourceReference,
              reference.source == c.source, !reference.recordId.isEmpty, reference.recordId == c.sourceRecordId else {
            throw ImportedSource.failure(c.unsupportedReason ?? "导入缺少经过验证的来源引用")
        }
        let existing = ProviderRegistry.scan(dir: userDir)
        guard !existing.contains(where: { $0.manifest.sourceReference?.sameSourceRecord(as: reference) == true }) else {
            throw ImportedSource.failure("该来源账号已导入，不会覆盖现有配置")
        }
        let record = try ImportedSource.read(reference)
        let legacy = existing.filter { $0.manifest.sourceReference == nil && matchesExisting(c, manifest: $0.manifest) }
        guard legacy.count <= 1 else { throw ImportedSource.failure("多个旧账号对应同一来源，请先确认原账号") }
        if let account = legacy.first {
            return try convertLegacy(c, reference: reference, record: record, account: account,
                                     userDir: userDir, hudDir: hudDir)
        }
        let template: PluginProvider?
        if let slug = c.template {
            guard let found = templates.first(where: { $0.slug == slug }) else { throw ImportedSource.failure("导入类型模板已不存在") }
            guard found.manifest.supportsQuota,
                  found.manifest.quotaAuthModes.map({ $0.contains(record.authMode) }) ?? true,
                  !["jwt", "cookie"].contains(found.manifest.queryAuth ?? "") || found.manifest.inheritQueryUrl != nil else {
                throw ImportedSource.failure("该类型未提供继承当前认证的额度适配")
            }
            template = found
        } else { template = nil }
        let slug = uniqueSlug(PluginGenerator.slugify(c.slugHint ?? c.name), userDir: userDir)
        let staging = userDir.appendingPathComponent(".tokenhud-import-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedProviders = staging.appendingPathComponent("providers", isDirectory: true)
        let stagedHud = staging.appendingPathComponent("hud", isDirectory: true)
        try fm.createDirectory(at: stagedProviders, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagedHud, withIntermediateDirectories: true)
        let stagedAuth = PluginGenerator.expandPath(PluginGenerator.authPath(slug: slug, hudDir: stagedHud))
        var manifest: ProviderManifest
        let script: String
        if let template {
            manifest = try PluginGenerator.instantiate(template: template, slug: slug, name: c.name,
                into: stagedProviders, hudDir: stagedHud)
            script = try String(contentsOf: stagedProviders.appendingPathComponent(slug + "/fetch.sh"), encoding: .utf8)
        } else {
            guard record.authMode == "apikey", validEndpoint(record.baseURL),
                  ["openai", "chat", "responses", "anthropic"].contains(record.protocolName) else {
                throw ImportedSource.failure("该来源缺少可用的通用调用接口")
            }
            var config = ProviderConfig()
            config.refreshProtocol = record.protocolName
            config.refreshHeader = record.protocolName == "anthropic"
                ? "x-api-key: <key>\nanthropic-version: 2023-06-01" : "Authorization: Bearer <key>"
            // Generic endpoints are resolved from the source each time, not saved as stale overrides.
            manifest = PluginGenerator.customManifest(name: c.name, config: config,
                authFile: PluginGenerator.authPath(slug: slug, hudDir: stagedHud))
            manifest.cacheFile = PluginGenerator.cachePath(slug: slug, hudDir: hudDir)
            script = PluginGenerator.oneAPIFetchScript(slug: slug)
        }
        manifest.sourceReference = reference
        manifest.origin = c.origin
        manifest.authMode = record.authMode
        manifest.authFile = PluginGenerator.authPath(slug: slug, hudDir: hudDir)
        manifest.cacheFile = PluginGenerator.cachePath(slug: slug, hudDir: hudDir)
        var config = ProviderConfigStore.read(authFile: stagedAuth, manifest: manifest)
        config.authMode = record.authMode
        config.refreshKey = ""
        config.authCredentialFile = ""
        // Runtime validation is read-only and proves the reference still resolves before commit.
        _ = try ProviderAuthentication.resolveBase(config)
        if template != nil { _ = try ProviderAuthentication.resolveQuota(config) }
        try ProviderConfigStore.write(config, manifest: manifest, to: stagedAuth)
        try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: script, into: stagedProviders)
        let finalAuth = PluginGenerator.expandPath(PluginGenerator.authPath(slug: slug, hudDir: hudDir))
        try fm.createDirectory(at: finalAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: finalAuth.path) else { throw ImportedSource.failure("本地账号配置文件已存在") }
        let finalPlugin = userDir.appendingPathComponent(slug).standardizedFileURL
        guard finalPlugin.deletingLastPathComponent().path == userDir.standardizedFileURL.path else {
            throw ImportedSource.failure("账号目录超出应用配置范围")
        }
        try fm.moveItem(at: stagedProviders.appendingPathComponent(slug), to: finalPlugin)
        do { try fm.moveItem(at: stagedAuth, to: finalAuth) }
        catch {
            try fm.moveItem(at: finalPlugin, to: stagedProviders.appendingPathComponent(slug))
            throw error
        }
        return slug
    }

    /// Converts only an origin-bound legacy account; manual accounts never enter this path.
    private static func convertLegacy(_ candidate: ImportCandidate, reference: ProviderSourceReference,
                                      record: SourceRecord, account: PluginProvider,
                                      userDir: URL, hudDir: URL) throws -> String {
        guard account.manifest.template == candidate.template else {
            throw ImportedSource.failure("来源供应商类型与旧账号不一致，请移除本地关联后重新导入")
        }
        if account.manifest.template == nil {
            func normalizedProtocol(_ value: String?) -> String? {
                value == "chat" ? "openai" : value
            }
            guard normalizedProtocol(account.manifest.refreshProtocol) == normalizedProtocol(record.protocolName),
                  normalizedProtocol(candidate.proto) == normalizedProtocol(record.protocolName) else {
                throw ImportedSource.failure("来源调用协议与旧账号不一致，请移除本地关联后重新导入")
            }
        }
        let fm = FileManager.default
        let slug = account.slug
        let manifestURL = account.dir.appendingPathComponent("manifest.json")
        let authURL = PluginGenerator.expandPath(PluginGenerator.authPath(slug: slug, hudDir: hudDir))
        let cacheURL = PluginGenerator.expandPath(PluginGenerator.cachePath(slug: slug, hudDir: hudDir))
        let expectedAuth = account.manifest.authFile.map(PluginGenerator.expandPath)
        guard account.dir.standardizedFileURL.deletingLastPathComponent().path == userDir.standardizedFileURL.path,
              expectedAuth?.standardizedFileURL.path == authURL.standardizedFileURL.path,
              authURL.resolvingSymlinksInPath().deletingLastPathComponent().path == hudDir.resolvingSymlinksInPath().path,
              cacheURL.resolvingSymlinksInPath().deletingLastPathComponent().path == hudDir.resolvingSymlinksInPath().path,
              ![manifestURL, authURL, cacheURL].contains(where: {
                  $0.resolvingSymlinksInPath() == URL(fileURLWithPath: reference.path).resolvingSymlinksInPath()
              }) else {
            throw ImportedSource.failure("旧账号不在当前应用的独立配置目录，无法安全转换")
        }
        let oldManifest = try Data(contentsOf: manifestURL)
        let oldAuth = fm.fileExists(atPath: authURL.path) ? try Data(contentsOf: authURL) : nil
        let oldCache = fm.fileExists(atPath: cacheURL.path) ? try Data(contentsOf: cacheURL) : nil
        var manifest = account.manifest
        manifest.sourceReference = reference
        manifest.origin = candidate.origin
        manifest.authMode = record.authMode
        if manifest.template == nil {
            manifest.refreshProtocol = record.protocolName
            manifest.refreshUrl = nil
            manifest.refreshHeader = record.protocolName == "anthropic"
                ? "x-api-key: <key>\nanthropic-version: 2023-06-01" : "Authorization: Bearer <key>"
        }
        var config = ProviderConfigStore.read(authFile: authURL, manifest: manifest)
        config.refreshKey = ""
        config.authCredentialFile = ""
        config.authMode = record.authMode
        _ = try ProviderAuthentication.resolveBase(config)
        let staging = userDir.appendingPathComponent(".tokenhud-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedAuth = staging.appendingPathComponent("account.json")
        try ProviderConfigStore.write(config, manifest: manifest, to: stagedAuth)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedManifest = try encoder.encode(manifest)
        let updatedAuth = try Data(contentsOf: stagedAuth)
        do {
            try updatedAuth.write(to: authURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
            try updatedManifest.write(to: manifestURL, options: .atomic)
            if oldCache != nil { try fm.removeItem(at: cacheURL) }
        } catch {
            do {
                try oldManifest.write(to: manifestURL, options: .atomic)
                if let oldAuth { try oldAuth.write(to: authURL, options: .atomic) }
                else if fm.fileExists(atPath: authURL.path) { try fm.removeItem(at: authURL) }
                if let oldCache { try oldCache.write(to: cacheURL, options: .atomic) }
            } catch {
                throw ImportedSource.failure("旧账号转换失败且回滚未完成，请检查本地账号配置")
            }
            throw error
        }
        return slug
    }

    static func matchesExisting(_ c: ImportCandidate, manifest: ProviderManifest) -> Bool {
        if let reference = c.sourceReference, manifest.sourceReference?.sameSourceRecord(as: reference) == true { return true }
        // A modern reference from another path/collection is a distinct source instance.
        guard manifest.sourceReference == nil, !c.sourceRecordId.isEmpty else { return false }
        return manifest.origin == c.origin || manifest.origin == "\(c.source):\(c.sourceRecordId)"
    }

    private static func query(_ db: String, _ sql: String) -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        return (try? ReadonlySQLite.query(path: db, sql: sql)) ?? []
    }

    private static func readObject(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap(json)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func triggerURLForTest(_ base: String, _ proto: String) -> String {
        APIEndpoint.requestURL(baseURL: base, protocolName: proto)
    }

    private static func uniqueSlug(_ base: String, userDir: URL) -> String {
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: userDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        return slug
    }
}
