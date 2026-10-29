import Foundation

struct ProviderManifest: Codable {
    let name: String
    let label: String
    var displayName: String?   // 完整显示名 (如 "OpenCode Go"); nil 用 label
    var fetch: String
    var intervalSec: Int?
    var buckets: [String: String]
    var cacheFile: String?
    var authFile: String?       // 凭证文件路径 (如 ~/.claude/hud/.ollama-usage-auth.json)
    var needsCredential: Bool?  // 无 API 查余额, 需登录凭证 (如 glm JWT)
    var testModel: String?      // 额度刷新测试 model (如 glm-4.7)
    var testPrompt: String?     // 额度刷新测试 prompt
    var queryUrl: String?       // 查余额 url (缺省用 auth.apiUrl/url)
    var queryAuth: String?      // 查余额凭证类型: jwt/bearer/cookie/header
    /// 查余额凭证在 auth 文件里的字段名 (如 "apiKey"); 声明后 read/write 直接读写该字段, 不走 headers.Authorization
    var queryKeyField: String?
    var refreshUrl: String?      // 触发滚动窗口 url
    var refreshProtocol: String? // 刷新协议: anthropic/openai
    var refreshAuth: String?    // 刷新凭证类型: bearer/cookie
    var refreshHeader: String?  // 刷新 header 模板 (<key> 占位)
    var builtin: Bool?         // (废弃) 旧内置标志: 仅向后兼容旧用户 manifest 读取
    /// 所属类型模板 slug (脚本型实例指向 bundle 模板; nil = 通用自定义型)
    var template: String?
    var accent: String?         // 品牌色名 (blue/green/purple/orange/teal…), UI 不再硬编码 slug
    var icon: String?           // SF Symbol 名 (如 "brain"); 缺省用 label 首字母
    var enabled: Bool?
    /// 授权模式: apikey (粘贴密钥) / local (读本机 CLI 已登录凭证) / oauth (预留)
    /// 只影响 UI 表单呈现, 不影响解析 (解析在各 provider 脚本)
    var authMode: String?

    var isEnabled: Bool { enabled ?? true }
    var interval: Int { intervalSec ?? 60 }
    var fullName: String { displayName ?? label }
    var requiresCredential: Bool { needsCredential ?? false }
    var refreshModel: String { testModel ?? "" } // 缺省空: 空则触发时提示配置 (不应默认某家私有模型)
    var isBuiltin: Bool { builtin ?? false }

    /// authMode 归一: manifest 未声明时按 queryAuth 推断 (header 型=读本机凭证)
    var authStyle: String { authMode ?? (queryAuth == "header" ? "local" : "apikey") }

    private enum CodingKeys: String, CodingKey {
        case name, label, displayName, fetch, intervalSec, buckets, cacheFile, authFile, needsCredential, testModel, testPrompt, queryUrl, queryAuth, queryKeyField, refreshUrl, refreshProtocol, refreshAuth, refreshHeader, builtin, template, accent, icon, enabled, authMode
    }

    init(name: String, label: String, displayName: String? = nil, fetch: String = "./fetch.sh",
         intervalSec: Int? = nil, buckets: [String: String] = [:], cacheFile: String? = nil,
         authFile: String? = nil, needsCredential: Bool? = nil, testModel: String? = nil,
         testPrompt: String? = nil, queryUrl: String? = nil, queryAuth: String? = nil,
         queryKeyField: String? = nil,
         refreshUrl: String? = nil, refreshProtocol: String? = nil, refreshAuth: String? = nil,
         refreshHeader: String? = nil, builtin: Bool? = nil, template: String? = nil,
         accent: String? = nil, icon: String? = nil, enabled: Bool? = true,
         authMode: String? = nil) {
        self.name = name
        self.label = label
        self.displayName = displayName
        self.fetch = fetch
        self.intervalSec = intervalSec
        self.buckets = buckets
        self.cacheFile = cacheFile
        self.authFile = authFile
        self.needsCredential = needsCredential
        self.testModel = testModel
        self.testPrompt = testPrompt
        self.queryUrl = queryUrl
        self.queryAuth = queryAuth
        self.queryKeyField = queryKeyField
        self.refreshUrl = refreshUrl
        self.refreshProtocol = refreshProtocol
        self.refreshAuth = refreshAuth
        self.refreshHeader = refreshHeader
        self.builtin = builtin
        self.template = template
        self.accent = accent
        self.icon = icon
        self.enabled = enabled
        self.authMode = authMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decode(String.self, forKey: .label)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        fetch = try c.decodeIfPresent(String.self, forKey: .fetch) ?? "./fetch.sh"
        intervalSec = try c.decodeIfPresent(Int.self, forKey: .intervalSec)
        buckets = try c.decodeIfPresent([String: String].self, forKey: .buckets) ?? [:]
        cacheFile = try c.decodeIfPresent(String.self, forKey: .cacheFile)
        authFile = try c.decodeIfPresent(String.self, forKey: .authFile)
        needsCredential = try c.decodeIfPresent(Bool.self, forKey: .needsCredential)
        testModel = try c.decodeIfPresent(String.self, forKey: .testModel)
        testPrompt = try c.decodeIfPresent(String.self, forKey: .testPrompt)
        queryUrl = try c.decodeIfPresent(String.self, forKey: .queryUrl)
        queryAuth = try c.decodeIfPresent(String.self, forKey: .queryAuth)
        queryKeyField = try c.decodeIfPresent(String.self, forKey: .queryKeyField)
        refreshUrl = try c.decodeIfPresent(String.self, forKey: .refreshUrl)
        refreshProtocol = try c.decodeIfPresent(String.self, forKey: .refreshProtocol)
        refreshAuth = try c.decodeIfPresent(String.self, forKey: .refreshAuth)
        refreshHeader = try c.decodeIfPresent(String.self, forKey: .refreshHeader)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode)
    }
}

struct Bucket: Codable {
    var usedPercentage: Double?
    /// 整数 epoch 秒 (glm 等) 或 ISO8601 字符串 (ollama /api/balance) — 统一存 epoch 秒
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    init(usedPercentage: Double? = nil, resetsAt: Int? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercentage = try c.decodeIfPresent(Double.self, forKey: .usedPercentage)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .resetsAt) {
            resetsAt = n
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil {
            let f = ISO8601DateFormatter()
            resetsAt = f.date(from: s).map { Int($0.timeIntervalSince1970) }
        } else {
            resetsAt = nil
        }
    }
}

struct UsageCache: Codable {
    var generatedAt: Double?
    var fiveHour: Bucket?
    var sevenDay: Bucket?
    var monthly: Bucket?
    var error: String?
    var stale: Bool?

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case monthly
        case error, stale
    }

    /// 解析 fetch.sh stdout（可缺 generatedAt/ttlMs 等字段），统一盖上框架字段
    static func make(body: Data, now: Double) -> UsageCache? {
        guard let raw = try? JSONDecoder().decode(UsageCache.self, from: body) else { return nil }
        var c = raw
        c.generatedAt = now
        c.stale = false
        if c.error == nil, c.fiveHour == nil, c.sevenDay == nil, c.monthly == nil { return nil }
        return c
    }
}

/// 一个已装载的插件（manifest + 所在目录）
struct PluginProvider {
    let slug: String
    let manifest: ProviderManifest
    let dir: URL
}

extension PluginProvider: Identifiable {
    var id: String { slug }
}
