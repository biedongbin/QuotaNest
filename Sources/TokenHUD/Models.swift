import Foundation

/// One complete credential layout, selected atomically from a single authorization file.
struct ProviderCredentialFormat: Codable, Equatable, Sendable {
    var tokenPath: String
    var headerPaths: [String: String]?
    var requiredValues: [String: String]?
    var contextPaths: [String: String]?
    var tokenEncoding: String? = nil
}

/// Declares stable account evidence for cross-source deduplication, separate from access-token bytes.
struct ProviderAccountIdentityRule: Codable, Equatable, Sendable {
    let namespace: String
    let subjectClaim: String
    let workspaceHeader: String
    var workspaceClaim: String? = nil
    var allowedIssuers: [String]? = nil
}

/// Declares an existing CLI authorization file; no token is copied into account settings.
struct ProviderCredentialSource: Codable, Equatable, Sendable {
    var file: String
    var environmentDirectory: String?
    var tokenPath: String
    var headerPaths: [String: String]?
    var requiredValues: [String: String]?
    var fileConfigKey: String?
    var contextPaths: [String: String]?
    var alternatives: [ProviderCredentialFormat]?
    var tokenEncoding: String? = nil
    var accountIdentity: ProviderAccountIdentityRule? = nil
    var importProviders: [String]? = nil
    var importPriority: Int? = nil
}

/// A live, read-only reference. Never contains credentials.
struct ProviderSourceReference: Codable, Equatable, Sendable {
    let source: String
    let path: String
    let recordId: String
    var providerId: String? = nil
    var collection: String? = nil
    var credentialProviderId: String? = nil
    var identityAnchor: String? = nil
    var originalRecordId: String? = nil
    var originalProviderId: String? = nil
    var identityProtocol: String? = nil
    var identityEndpoint: String? = nil
    var identityProviderType: String? = nil
    var identityAccount: String? = nil
}

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
    /// 导入来源标识 "source:recordId" (9router:<id>/cc-switch:<id>/cpamp:<文件名>); 手建账号 nil
    /// 导入查重按它判 (同源同记录 = 已存在), 不按显示名
    var origin: String?
    /// none: 仅管理与调用；endpoint: 标准 JSON 额度接口；script: 类型提供的解析器。
    var quotaMode: String?
    var quotaAuthModes: [String]?
    var credentialSource: ProviderCredentialSource?
    var authCallUrl: String?
    var authCallProtocol: String?
    var authCallHeader: String?
    var authModelsUrl: String?
    var inheritQueryUrl: String?
    var inheritQueryHeader: String?
    /// nil preserves automatic default account creation for existing templates.
    var autoCreateDefault: Bool?
    var sourceReference: ProviderSourceReference?

    var isSourceConfigurationReadOnly: Bool { sourceReference != nil || origin?.isEmpty == false }

    var supportsQuota: Bool {
        if let quotaMode { return quotaMode != "none" }
        return queryUrl?.isEmpty == false || cacheFile != nil
    }

    var isEnabled: Bool { enabled ?? true }
    var interval: Int { intervalSec ?? 60 }
    var fullName: String { displayName ?? label }
    var requiresCredential: Bool { needsCredential ?? false }
    var refreshModel: String { testModel ?? "" } // 缺省空: 空则触发时提示配置 (不应默认某家私有模型)
    var isBuiltin: Bool { builtin ?? false }

    /// authMode 归一: manifest 未声明时按 queryAuth 推断 (header 型=读本机凭证)
    var authStyle: String { authMode ?? (queryAuth == "header" ? "local" : "apikey") }

    private enum CodingKeys: String, CodingKey {
        case name, label, displayName, fetch, intervalSec, buckets, cacheFile, authFile, needsCredential, testModel, testPrompt, queryUrl, queryAuth, queryKeyField, refreshUrl, refreshProtocol, refreshAuth, refreshHeader, builtin, template, accent, icon, enabled, authMode, origin, quotaMode, quotaAuthModes, credentialSource, authCallUrl, authCallProtocol, authCallHeader, authModelsUrl, inheritQueryUrl, inheritQueryHeader, autoCreateDefault, sourceReference
    }

    init(name: String, label: String, displayName: String? = nil, fetch: String = "./fetch.sh",
         intervalSec: Int? = nil, buckets: [String: String] = [:], cacheFile: String? = nil,
         authFile: String? = nil, needsCredential: Bool? = nil, testModel: String? = nil,
         testPrompt: String? = nil, queryUrl: String? = nil, queryAuth: String? = nil,
         queryKeyField: String? = nil,
         refreshUrl: String? = nil, refreshProtocol: String? = nil, refreshAuth: String? = nil,
         refreshHeader: String? = nil, builtin: Bool? = nil, template: String? = nil,
         accent: String? = nil, icon: String? = nil, enabled: Bool? = true,
         authMode: String? = nil, origin: String? = nil, quotaMode: String? = nil,
         quotaAuthModes: [String]? = nil, credentialSource: ProviderCredentialSource? = nil,
         authCallUrl: String? = nil, authCallProtocol: String? = nil, authCallHeader: String? = nil,
         authModelsUrl: String? = nil, inheritQueryUrl: String? = nil, inheritQueryHeader: String? = nil,
         autoCreateDefault: Bool? = nil, sourceReference: ProviderSourceReference? = nil) {
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
        self.origin = origin
        self.quotaMode = quotaMode
        self.quotaAuthModes = quotaAuthModes
        self.credentialSource = credentialSource
        self.authCallUrl = authCallUrl
        self.authCallProtocol = authCallProtocol
        self.authCallHeader = authCallHeader
        self.authModelsUrl = authModelsUrl
        self.inheritQueryUrl = inheritQueryUrl
        self.inheritQueryHeader = inheritQueryHeader
        self.autoCreateDefault = autoCreateDefault
        self.sourceReference = sourceReference
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
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        quotaMode = try c.decodeIfPresent(String.self, forKey: .quotaMode)
        quotaAuthModes = try c.decodeIfPresent([String].self, forKey: .quotaAuthModes)
        credentialSource = try c.decodeIfPresent(ProviderCredentialSource.self, forKey: .credentialSource)
        authCallUrl = try c.decodeIfPresent(String.self, forKey: .authCallUrl)
        authCallProtocol = try c.decodeIfPresent(String.self, forKey: .authCallProtocol)
        authCallHeader = try c.decodeIfPresent(String.self, forKey: .authCallHeader)
        authModelsUrl = try c.decodeIfPresent(String.self, forKey: .authModelsUrl)
        inheritQueryUrl = try c.decodeIfPresent(String.self, forKey: .inheritQueryUrl)
        inheritQueryHeader = try c.decodeIfPresent(String.self, forKey: .inheritQueryHeader)
        autoCreateDefault = try c.decodeIfPresent(Bool.self, forKey: .autoCreateDefault)
        sourceReference = try c.decodeIfPresent(ProviderSourceReference.self, forKey: .sourceReference)
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

/// P1-11 动态窗口: provider 上报的真实计费窗口 (全字段可选, 解码容错)
/// 旧 fiveHour/sevenDay/monthly 保留做投影, HUD/statusline 读端不动
struct WindowBucket: Codable, Equatable {
    var label: String?             // 中文窗口名 ("5小时"/"本周"/"本月"/"滚动"/…)
    var usedPercentage: Double?
    var remainingPercentage: Double?
    var amount: Double?            // 按 unit 的测量值；周期表示已用量，period=balance 表示 label 明确的剩余余额
    var limit: Double?             // 总额度 (按 unit)
    var unit: String?              // "USD" / "requests" / …
    var period: String?            // 周期描述
    var resetsAt: Int?

    /// Standard labels emitted by the bundled adapters; custom provider labels
    /// remain data and are displayed exactly as returned.
    var displayLabel: String? { localizedLabel(language: AppLanguageSettings.shared.selection) }

    func localizedLabel(language: AppLanguage) -> String? {
        guard let label else { return nil }
        switch label {
        case "5小时", "本周", "本月", "余额", "剩余 Credits", "月剩余余额", "额度窗口":
            return L10n.tr(label, language: language)
        default: return label
        }
    }

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
        case amount, limit, unit, period
        case resetsAt = "resets_at"
    }

    init(label: String? = nil, usedPercentage: Double? = nil, remainingPercentage: Double? = nil,
         amount: Double? = nil, limit: Double? = nil, unit: String? = nil,
         period: String? = nil, resetsAt: Int? = nil) {
        self.label = label
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
        self.amount = amount
        self.limit = limit
        self.unit = unit
        self.period = period
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        usedPercentage = WindowBucket.flexibleDouble(c, .usedPercentage)
        remainingPercentage = WindowBucket.flexibleDouble(c, .remainingPercentage)
        amount = WindowBucket.flexibleDouble(c, .amount)
        limit = WindowBucket.flexibleDouble(c, .limit)
        unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        period = try? c.decodeIfPresent(String.self, forKey: .period)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .resetsAt) {
            resetsAt = n
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil {
            resetsAt = ISO8601DateFormatter().date(from: s).map { Int($0.timeIntervalSince1970) }
        } else {
            resetsAt = nil
        }
    }

    /// 数值字段容错: number / 整数串 ("12") / null 均可
    private static func flexibleDouble(_ c: KeyedDecodingContainer<CodingKeys>,
                                       _ key: CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

struct UsageCache: Codable {
    /// P2-3 存储版本化: 顶层 schemaVersion, 写入带 1, 读取缺省=1 (读端零改动兼容)
    var schemaVersion: Int?
    /// 最近成功快照时间 (= snapshotCapturedAt/lastSuccessAt): 仅业务成功更新, 失败不推进 (FR-03.8)
    var generatedAt: Double?
    var fiveHour: Bucket?
    var sevenDay: Bucket?
    var monthly: Bucket?
    var error: String?
    var stale: Bool?
    /// 最近尝试时间: 每次尝试都更新 (失败也更新); 引擎 due 判定/statusline spawn 抑制用它, 旧缓存缺省回退 generatedAt
    var lastAttemptAt: Double?
    /// P1-11 动态窗口列表: provider 按各自真实窗口上报 (可缺); 旧三桶保留做投影, 旧读端不破坏
    var windows: [WindowBucket]?
    /// 供应商用于判断缓存归属的标识；不参与展示或日志。
    var accountId: String?
    /// Digest of the live source snapshot; never raw source credentials.
    var sourceRevision: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, lastAttemptAt, windows, sourceRevision
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case accountId = "account_id"
        case monthly
        case error, stale
    }

    init(schemaVersion: Int? = nil, generatedAt: Double? = nil, fiveHour: Bucket? = nil, sevenDay: Bucket? = nil,
         monthly: Bucket? = nil, error: String? = nil, stale: Bool? = nil,
         lastAttemptAt: Double? = nil, windows: [WindowBucket]? = nil, accountId: String? = nil,
         sourceRevision: String? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.monthly = monthly
        self.error = error
        self.stale = stale
        self.lastAttemptAt = lastAttemptAt
        self.windows = windows
        self.accountId = accountId
        self.sourceRevision = sourceRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // P2-3: 读取缺省 = 1 (旧缓存无此字段)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decodeIfPresent(Double.self, forKey: .generatedAt)
        fiveHour = try c.decodeIfPresent(Bucket.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(Bucket.self, forKey: .sevenDay)
        monthly = try c.decodeIfPresent(Bucket.self, forKey: .monthly)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        lastAttemptAt = try c.decodeIfPresent(Double.self, forKey: .lastAttemptAt)
        windows = try c.decodeIfPresent([WindowBucket].self, forKey: .windows)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        sourceRevision = try c.decodeIfPresent(String.self, forKey: .sourceRevision)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion ?? 1, forKey: .schemaVersion)
        try c.encodeIfPresent(generatedAt, forKey: .generatedAt)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
        try c.encodeIfPresent(monthly, forKey: .monthly)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(stale, forKey: .stale)
        try c.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
        try c.encodeIfPresent(windows, forKey: .windows)
        try c.encodeIfPresent(accountId, forKey: .accountId)
        try c.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
    }

    /// 解析 fetch.sh stdout（可缺 generatedAt/ttlMs 等字段），统一盖上框架字段
    static func make(body: Data, now: Double) -> UsageCache? {
        guard var raw = try? JSONDecoder().decode(UsageCache.self, from: body) else { return nil }
        raw.lastAttemptAt = now
        raw.schemaVersion = 1
        if raw.error == nil {
            // 仅业务成功推进 generatedAt; 失败保留脚本写入的旧值 (FR-03.8 失败不推进成功时间)
            raw.generatedAt = now
            raw.stale = false
        }
        let hasLegacy = raw.fiveHour != nil || raw.sevenDay != nil || raw.monthly != nil
        if raw.error == nil, !hasLegacy, (raw.windows ?? []).isEmpty { return nil }
        return raw
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
