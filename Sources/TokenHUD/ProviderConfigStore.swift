import Foundation

/// 供应商编辑配置: 统一读写 auth 文件, 由 manifest 声明协议差异
/// 上栏 = 查余额 (queryUrl + queryKey + queryToken + queryHeader)
/// 下栏 = 触发滚动窗口 (refreshUrl + refreshKey + refreshHeader + testModel + testPrompt)
/// 协议差异 (url/header/凭证类型) 全部来自 manifest.json, 主框架不感知具体供应商
struct ProviderConfig {
    var queryUrl: String = ""
    var queryKey: String = ""       // apikey (bearer)
    var queryToken: String = ""     // accessToken (jwt)
    var queryCookie: String = ""    // cookie
    var queryHeader: String = ""
    var refreshUrl: String = ""
    var refreshKey: String = ""
    var refreshHeader: String = ""
    var refreshProtocol: String = "anthropic"  // 刷新协议: anthropic / openai
    var testModel: String = ""
    var testPrompt: String = "test，收到回复1"
    var scheduleTimes: [String] = []  // 定时触发时间点 (HH:MM), 到点自动发 chat 请求
}

enum ProviderConfigStore {
    /// 读配置: 协议字段从 manifest 取, 凭证从 auth 文件取
    static func read(authFile: URL, manifest: ProviderManifest) -> ProviderConfig {
        guard let data = try? Data(contentsOf: authFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ProviderConfig() }
        var c = ProviderConfig()
        let headers = obj["headers"] as? [String: Any] ?? [:]
        c.scheduleTimes = obj["scheduleTimes"] as? [String] ?? []

        // 查余额 url: manifest.queryUrl 优先, 缺省 auth.apiUrl/url
        c.queryUrl = manifest.queryUrl ?? (obj["apiUrl"] as? String) ?? (obj["url"] as? String) ?? ""
        // 查余额凭证: 按 manifest.queryAuth 类型取
        switch manifest.queryAuth {
        case "jwt":
            c.queryToken = headers["authorization"] as? String ?? ""
            c.queryHeader = headerString(headers)
        case "cookie":
            c.queryCookie = obj["cookieAuth"] as? String ?? ""
            c.queryHeader = "cookie: <key>"
        case "header":
            c.queryHeader = headerString(headers)
        default: // bearer
            if let field = manifest.queryKeyField {
                // 声明字段名: 凭证单一事实源 = auth.<field> (如 cline 的 apiKey, mjs 直读此字段)
                c.queryKey = obj[field] as? String ?? ""
            } else if manifest.template != nil {
                // 脚本型: 凭证单一事实源 = refreshApiKey (固化 mjs 即读此字段), 回退 headers.Authorization
                c.queryKey = ((obj["refreshApiKey"] as? String) ?? "").isEmpty
                    ? bearer(headers["Authorization"] as? String)
                    : (obj["refreshApiKey"] as? String ?? "")
            } else {
                c.queryKey = bearer(headers["Authorization"] as? String)
            }
            c.queryHeader = headerString(headers)
        }

        // 刷新: url/协议/header 全从 manifest
        c.refreshUrl = manifest.refreshUrl ?? ""
        c.refreshProtocol = manifest.refreshProtocol ?? "anthropic"
        c.refreshHeader = manifest.refreshHeader ?? "Authorization: Bearer <key>"
        // 刷新凭证: manifest.refreshAuth 决定取哪个字段
        switch manifest.refreshAuth {
        case "cookie":
            c.refreshKey = obj["cookieAuth"] as? String ?? ""
        default: // bearer
            // refreshApiKey 优先, 缺省回退 headers.Authorization (如 ollama)
            c.refreshKey = (obj["refreshApiKey"] as? String) ?? bearer(headers["Authorization"] as? String)
        }

        c.testModel = obj["testModel"] as? String ?? ""
        c.testPrompt = obj["testPrompt"] as? String ?? "test，收到回复1"
        return c
    }

    /// 写配置: 凭证按 manifest 类型写回 auth 文件, 协议字段不写 (manifest 锁定)
    static func write(_ c: ProviderConfig, manifest: ProviderManifest, to authFile: URL) throws {
        guard let data = try? Data(contentsOf: authFile),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NSError(domain: "ProviderConfigStore", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "auth 文件读取失败"]) }

        // 查余额凭证
        switch manifest.queryAuth {
        case "jwt":
            var h = obj["headers"] as? [String: Any] ?? [:]
            h["authorization"] = c.queryToken
            obj["headers"] = h
        case "cookie":
            obj["cookieAuth"] = c.queryCookie
        case "header": // 无凭证 (如 gpt 看板), headers 不动
            break
        default: // bearer
            if let field = manifest.queryKeyField {
                // 声明字段名: 凭证单一事实源 = auth.<field>; headers 原样保留 (mjs 直读该字段)
                obj[field] = c.queryKey
            } else {
                var h = obj["headers"] as? [String: Any] ?? [:]
                h["Authorization"] = "Bearer \(c.queryKey)"
                obj["headers"] = h
                if manifest.template != nil {
                    obj["refreshApiKey"] = c.queryKey  // 脚本型: mjs 读此字段
                }
            }
        }
        // 脚本型实例: 查询配置 (url) 存 auth 文件 (固化 mjs 从 auth.apiUrl 抓取)
        // generic 实例的 queryUrl 进 manifest, 不入 auth
        if manifest.template != nil {
            obj["apiUrl"] = c.queryUrl
        }
        // 刷新凭证
        switch manifest.refreshAuth {
        case "cookie":
            obj["cookieAuth"] = c.refreshKey
        default: // bearer
            obj["refreshApiKey"] = c.refreshKey
        }
        // 可编辑字段: testModel/testPrompt 持久化到 auth 文件
        obj["testModel"] = c.testModel
        obj["testPrompt"] = c.testPrompt
        // 定时触发时间点
        if c.scheduleTimes.isEmpty {
            obj.removeValue(forKey: "scheduleTimes")
        } else {
            obj["scheduleTimes"] = c.scheduleTimes
        }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: authFile, options: .atomic)
    }

    /// 创建自定义供应商 auth 文件 (首次编辑)
    static func createCustom(slug: String, to authFile: URL) throws {
        let obj: [String: Any] = [
            "apiUrl": "",
            "headers": ["Authorization": "Bearer "],
            "refreshApiKey": "",
            "testModel": "",
            "testPrompt": "test，收到回复1",
        ]
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: authFile, options: .atomic)
    }

    private static func bearer(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "" }
        return v.hasPrefix("Bearer ") ? String(v.dropFirst(7)) : v
    }

    private static func headerString(_ headers: [String: Any]) -> String {
        headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }
}
