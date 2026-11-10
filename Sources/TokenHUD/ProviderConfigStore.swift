import Foundation

/// API 调用与额度查询共享基础认证，查询凭证仅在请求时解析。
struct ProviderConfig {
    var authMode = "apikey"
    var authCredentialFile = ""
    // Read-only capability metadata from the supplier declaration, never persisted credentials.
    var sourceReference: ProviderSourceReference?
    var sourceRevision: String?
    var sourceTemplate: String?
    var sourceEndpointIsFixed = false
    var isSourceConfigurationReadOnly = false
    var credentialsResolved = false
    var authContext: [String: String] = [:]
    var quotaAuthModes: [String]?
    var credentialSource: ProviderCredentialSource?
    var authCallURL: String?
    var authCallProtocol: String?
    var authCallHeader: String?
    var authModelsURL: String?
    var inheritQueryURL: String?
    var inheritQueryHeader: String?
    var queryAuth: String?

    var queryUrl = ""
    var queryKey = ""
    var queryHeader = ""
    var apiBaseURL = ""
    var refreshUrl = ""
    var refreshKey = ""
    var refreshHeader = ""
    var refreshProtocol = "anthropic"
    var testModel = ""
    var modelCatalog: ProviderModelCatalog?
    /// Local call preference; never changes an imported tool's model or credentials.
    var callModelOverride: String?
    var windowModelOverride: String?
    /// Saved base-model intent, separate from a temporary/verification call preference.
    var savedScheduleModel: String?
    var testPrompt = defaultPrompt
    var testMaxTokens = defaultMaxTokens
    var scheduleTimes: [String] = []
    var quotaMode = "none"

    /// Existing local plans win; saved base selections precede template defaults.
    func effectiveScheduleModel(manifest: ProviderManifest) -> String {
        let declared = manifest.windowTrigger.flatMap { $0.period == "five_hour" ? $0.model : nil }
        let selected = [windowModelOverride, savedScheduleModel, declared, testModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return modelCatalog?.canonicalModel(selected) ?? selected
    }

    static let defaultPrompt = "只回复OK"
    static let defaultMaxTokens = 16
}

enum ProviderConfigStore {
    static func applyingManifest(_ manifest: ProviderManifest, to config: ProviderConfig) -> ProviderConfig {
        var c = config
        c.modelCatalog = manifest.modelCatalog
        c.sourceReference = manifest.sourceReference
        c.sourceTemplate = manifest.template
        c.sourceEndpointIsFixed = manifest.template != nil
        c.isSourceConfigurationReadOnly = manifest.isSourceConfigurationReadOnly
        c.quotaAuthModes = manifest.quotaAuthModes
        c.credentialSource = manifest.credentialSource
        c.authCallURL = manifest.authCallUrl
        c.authCallProtocol = manifest.authCallProtocol
        c.authCallHeader = manifest.authCallHeader
        c.authModelsURL = manifest.authModelsUrl
        c.inheritQueryURL = manifest.inheritQueryUrl
        c.inheritQueryHeader = manifest.inheritQueryHeader
        c.queryAuth = manifest.queryAuth
        return c
    }

    static func read(authFile: URL, manifest: ProviderManifest) -> ProviderConfig {
        let obj = (try? Data(contentsOf: authFile)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        let headers = obj["headers"] as? [String: Any] ?? [:]
        var c = ProviderConfig()
        c.authMode = obj["authMode"] as? String ?? ((obj["refreshApiKey"] as? String)?.isEmpty == false ? "apikey" : ((manifest.authMode == "auth" || (manifest.credentialSource != nil && manifest.queryAuth == "header")) ? "auth" : "apikey"))
        let legacySource = manifest.credentialSource?.fileConfigKey.flatMap { obj[$0] as? String }
        c.authCredentialFile = obj["authCredentialFile"] as? String ?? legacySource ?? ""
        c.modelCatalog = manifest.modelCatalog
        c.sourceReference = manifest.sourceReference
        c.sourceTemplate = manifest.template
        c.sourceEndpointIsFixed = manifest.template != nil
        c.isSourceConfigurationReadOnly = manifest.isSourceConfigurationReadOnly
        c.quotaAuthModes = manifest.quotaAuthModes
        c.credentialSource = manifest.credentialSource
        c.authCallURL = manifest.authCallUrl
        c.authCallProtocol = manifest.authCallProtocol
        c.authCallHeader = manifest.authCallHeader
        c.authModelsURL = manifest.authModelsUrl
        c.inheritQueryURL = manifest.inheritQueryUrl
        c.inheritQueryHeader = manifest.inheritQueryHeader
        c.queryAuth = manifest.queryAuth
        c.quotaMode = (obj["quotaMode"] as? String) ?? manifest.quotaMode
            ?? (manifest.supportsQuota ? (manifest.template != nil ? "script" : "endpoint") : "none")
        c.queryUrl = manifest.queryUrl ?? (obj["queryUrl"] as? String)
            ?? (obj["apiUrl"] as? String) ?? (obj["url"] as? String) ?? ""
        c.refreshUrl = manifest.refreshUrl ?? (obj["refreshUrl"] as? String) ?? ""
        c.apiBaseURL = obj["apiBaseURL"] as? String ?? APIEndpoint.baseURL(from: c.refreshUrl)
        c.refreshProtocol = manifest.refreshProtocol ?? "anthropic"
        c.refreshHeader = manifest.refreshHeader ?? "Authorization: Bearer <key>"
        // Older shared API Key layouts can supply the base key, never web JWT/Cookie or queryKey.
        let schemaVersion = obj["schemaVersion"] as? Int ?? 1
        if let value = obj["refreshApiKey"] as? String, !value.isEmpty || schemaVersion >= 2 {
            c.refreshKey = value
        } else if let field = manifest.queryKeyField, field != "queryKey" {
            c.refreshKey = obj[field] as? String ?? ""
        } else if manifest.queryAuth == "bearer" || manifest.queryAuth == nil, manifest.refreshAuth != "cookie" {
            c.refreshKey = bearer(headers["Authorization"] as? String)
        }
        c.savedScheduleModel = obj["testModel"] as? String
        c.callModelOverride = obj["callModelOverride"] as? String
        c.windowModelOverride = obj["windowModelOverride"] as? String
        c.testModel = c.callModelOverride ?? obj["testModel"] as? String ?? manifest.testModel ?? ""
        c.testPrompt = obj["testPrompt"] as? String ?? manifest.testPrompt ?? ProviderConfig.defaultPrompt
        c.testMaxTokens = obj["testMaxTokens"] as? Int ?? manifest.testMaxTokens ?? ProviderConfig.defaultMaxTokens
        c.scheduleTimes = obj["scheduleTimes"] as? [String] ?? []
        if manifest.isSourceConfigurationReadOnly {
            c.refreshKey = ""
            c.queryKey = ""
            c.authContext = [:]
            c.authCredentialFile = ""
        }
        return c
    }

    static func write(_ c: ProviderConfig, manifest: ProviderManifest, to authFile: URL) throws {
        if (c.authMode == "auth" || c.sourceReference != nil || manifest.sourceReference != nil) && c.credentialsResolved {
            throw ProviderAuthenticationError(message: "已解析的 Auth 令牌只用于当前请求，不能写入账号配置")
        }
        guard !(manifest.isSourceConfigurationReadOnly || c.isSourceConfigurationReadOnly)
                || manifest.sourceReference != nil || c.sourceReference != nil else {
            throw ProviderAuthenticationError(message: "旧导入账号缺少实时来源引用，请重新导入")
        }
        let declared = applyingManifest(manifest, to: c)
        if let reference = manifest.sourceReference ?? c.sourceReference {
            let source = URL(fileURLWithPath: (reference.path as NSString).expandingTildeInPath)
            guard source.resolvingSymlinksInPath() != authFile.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ProviderAuthenticationError(message: "导入来源只读，不能覆盖来源文件")
            }
            // Rebuild from a whitelist: no inherited source key, APIkeyRef, headers or context survives.
            var object: [String: Any] = ["schemaVersion": 4,
                "sourceReference": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))]
            object["callModelOverride"] = c.callModelOverride
            object["windowModelOverride"] = c.windowModelOverride
            if !c.scheduleTimes.isEmpty { object["scheduleTimes"] = c.scheduleTimes }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: authFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
            return
        }
        if let source = ProviderAuthentication.credentialFileURL(for: declared),
           source.resolvingSymlinksInPath() == authFile.standardizedFileURL.resolvingSymlinksInPath() {
            throw ProviderAuthenticationError(message: "本机 Auth 授权文件只读，请使用独立的账号配置文件")
        }
        var obj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: authFile.path) {
            let data = try Data(contentsOf: authFile)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ProviderConfigStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "凭证配置必须是 JSON 对象"])
            }
            obj = existing
        }
        obj = removingQueryCredentials(from: obj, manifest: manifest)
        obj["queryUrl"] = c.queryUrl
        obj["quotaMode"] = c.quotaMode
        // 旧解析脚本仍读取 apiUrl，保留其格式；绝不写入 API 调用地址。
        obj["apiUrl"] = c.queryUrl
        obj["refreshApiKey"] = c.authMode == "auth" ? (obj["refreshApiKey"] as? String ?? "") : c.refreshKey
        obj["apiBaseURL"] = c.apiBaseURL
        obj["refreshUrl"] = c.refreshUrl
        // read() exposes the verification override as testModel; never persist it as base intent.
        if c.callModelOverride != nil {
            obj["testModel"] = c.savedScheduleModel ?? (obj["testModel"] as? String)
        } else {
            obj["testModel"] = c.testModel
        }
        obj["callModelOverride"] = c.callModelOverride
        obj["windowModelOverride"] = c.windowModelOverride
        obj["testPrompt"] = c.testPrompt
        obj["testMaxTokens"] = c.testMaxTokens
        obj["scheduleTimes"] = c.scheduleTimes.isEmpty ? nil : c.scheduleTimes
        obj["authMode"] = c.authMode
        obj["authCredentialFile"] = c.authCredentialFile
        obj["schemaVersion"] = 3
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    static func createCustom(slug: String, to authFile: URL) throws {
        try write(ProviderConfig(), manifest: ProviderManifest(name: slug, label: slug), to: authFile)
    }

    /// The caller invalidates its owned quota cache when saving removes an old query identity.
    static func hasObsoleteQueryCredentials(authFile: URL, manifest: ProviderManifest) -> Bool {
        guard let data = try? Data(contentsOf: authFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let cleaned = removingQueryCredentials(from: object, manifest: manifest)
        return !NSDictionary(dictionary: object).isEqual(to: cleaned)
    }

    /// Strip obsolete query identities while preserving unrelated user configuration.
    static func removingQueryCredentials(from original: [String: Any], manifest: ProviderManifest) -> [String: Any] {
        var object = original
        for key in ["queryKey", "queryToken", "queryCookie", "cookieAuth", "quotaCredentialMode", "token", "cookie", "authContext", "tokenhudAuthContext", "apiKeyRef", "APIkeyRef"]
            where key != manifest.credentialSource?.fileConfigKey {
            object.removeValue(forKey: key)
        }
        let baseFields: Set<String> = ["refreshApiKey", "authMode", "authCredentialFile", "queryUrl", "quotaMode", "scheduleTimes"]
        if let field = manifest.queryKeyField, !baseFields.contains(field), field != manifest.credentialSource?.fileConfigKey {
            object.removeValue(forKey: field)
        }
        if let headers = object["headers"] as? [String: Any] {
            let retained = headers.filter { !["authorization", "cookie"].contains($0.key.lowercased()) }
            object["headers"] = retained.isEmpty ? nil : retained
        }
        return object
    }

    private static func bearer(_ value: String?) -> String {
        guard let value else { return "" }
        return value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
    }
}
