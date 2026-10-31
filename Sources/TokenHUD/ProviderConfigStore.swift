import Foundation

/// API 调用与额度查询各自持有凭证，供应商类型只声明协议和解析方式。
struct ProviderConfig {
    var queryUrl = ""
    var queryKey = ""
    var queryToken = ""
    var queryCookie = ""
    var queryHeader = ""
    var apiBaseURL = ""
    var refreshUrl = ""
    var refreshKey = ""
    var refreshHeader = ""
    var refreshProtocol = "anthropic"
    var testModel = ""
    var testPrompt = defaultPrompt
    var testMaxTokens = defaultMaxTokens
    var scheduleTimes: [String] = []
    var quotaMode = "none"

    static let defaultPrompt = "只回复OK"
    static let defaultMaxTokens = 16
}

enum ProviderConfigStore {
    static func read(authFile: URL, manifest: ProviderManifest) -> ProviderConfig {
        let obj = (try? Data(contentsOf: authFile)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        let headers = obj["headers"] as? [String: Any] ?? [:]
        var c = ProviderConfig()
        c.quotaMode = manifest.quotaMode ?? (obj["quotaMode"] as? String)
            ?? (manifest.supportsQuota ? (manifest.template != nil ? "script" : "endpoint") : "none")
        c.queryUrl = manifest.queryUrl ?? (obj["queryUrl"] as? String)
            ?? (obj["apiUrl"] as? String) ?? (obj["url"] as? String) ?? ""
        c.queryToken = headers["authorization"] as? String ?? ""
        c.queryCookie = obj["cookieAuth"] as? String ?? ""
        if let value = obj["queryKey"] as? String {
            c.queryKey = value
        } else if let field = manifest.queryKeyField {
            c.queryKey = obj[field] as? String ?? ""
        } else {
            c.queryKey = bearer(headers["Authorization"] as? String)
            if c.queryKey.isEmpty, manifest.template != nil, manifest.queryAuth == "bearer" {
                c.queryKey = obj["refreshApiKey"] as? String ?? ""
            }
        }
        c.queryHeader = headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        c.refreshUrl = manifest.refreshUrl ?? (obj["refreshUrl"] as? String) ?? ""
        c.apiBaseURL = obj["apiBaseURL"] as? String ?? APIEndpoint.baseURL(from: c.refreshUrl)
        c.refreshProtocol = manifest.refreshProtocol ?? "anthropic"
        c.refreshHeader = manifest.refreshHeader ?? "Authorization: Bearer <key>"
        // v2 中空字符串有明确语义：不得偷偷回退另一能力的凭证。
        let schemaVersion = obj["schemaVersion"] as? Int ?? 1
        if let value = obj["refreshApiKey"] as? String, !value.isEmpty || schemaVersion >= 2 {
            c.refreshKey = value
        } else if manifest.refreshAuth == "cookie" {
            c.refreshKey = c.queryCookie
        } else {
            c.refreshKey = c.queryKey
        }
        c.testModel = obj["testModel"] as? String ?? manifest.testModel ?? ""
        c.testPrompt = obj["testPrompt"] as? String ?? manifest.testPrompt ?? ProviderConfig.defaultPrompt
        c.testMaxTokens = obj["testMaxTokens"] as? Int ?? ProviderConfig.defaultMaxTokens
        c.scheduleTimes = obj["scheduleTimes"] as? [String] ?? []
        return c
    }

    static func write(_ c: ProviderConfig, manifest: ProviderManifest, to authFile: URL) throws {
        var obj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: authFile.path) {
            let data = try Data(contentsOf: authFile)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ProviderConfigStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "凭证配置必须是 JSON 对象"])
            }
            obj = existing
        }
        var headers = obj["headers"] as? [String: Any] ?? [:]
        switch manifest.queryAuth {
        case "jwt": headers["authorization"] = c.queryToken
        case "cookie": obj["cookieAuth"] = c.queryCookie
        case "header": break // 外部 CLI 配置只读
        default:
            if let field = manifest.queryKeyField { obj[field] = c.queryKey }
            else { headers["Authorization"] = "Bearer \(c.queryKey)" }
        }
        if !headers.isEmpty { obj["headers"] = headers }
        obj["queryKey"] = c.queryKey
        obj["queryUrl"] = c.queryUrl
        obj["quotaMode"] = c.quotaMode
        obj["cookieAuth"] = c.queryCookie
        // 旧解析脚本仍读取 apiUrl，保留其格式；绝不写入 API 调用地址。
        obj["apiUrl"] = c.queryUrl
        obj["refreshApiKey"] = c.refreshKey
        obj["apiBaseURL"] = c.apiBaseURL
        obj["refreshUrl"] = c.refreshUrl
        obj["testModel"] = c.testModel
        obj["testPrompt"] = c.testPrompt
        obj["testMaxTokens"] = c.testMaxTokens
        obj["scheduleTimes"] = c.scheduleTimes.isEmpty ? nil : c.scheduleTimes
        obj["schemaVersion"] = 2
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    static func createCustom(slug: String, to authFile: URL) throws {
        try write(ProviderConfig(), manifest: ProviderManifest(name: slug, label: slug), to: authFile)
    }

    private static func bearer(_ value: String?) -> String {
        guard let value else { return "" }
        return value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
    }
}
