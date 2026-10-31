import Foundation

/// 第三方额度管理器的一键导入: 9router / cc-switch / cpamp(CLIProxyAPI)
/// 三家存储各异, 产物统一为 [ImportCandidate] → 落成 TokenHUD 供应商实例
struct ImportCandidate: Identifiable {
    let id = UUID()
    let source: String        // 9router / cc-switch / cpamp
    let name: String          // 建议显示名
    let template: String?     // 命中内置模板 slug (glm/ollama/opencode-go/cline); nil = 通用自定义
    let apiKey: String
    let baseURL: String       // 通用型的接口基址; 模板型留空
    let proto: String         // openai / anthropic (通用型触发协议)
    let note: String          // 副标题: 原始 provider/类型
    var exists = false        // 同名实例已存在
    /// 非 nil = 源里有这一行但无法转换成 TokenHUD 账号; 值即原因 (预览里显示"不支持")
    var unsupportedReason: String? = nil
    /// 源侧启用状态 (9router isActive); 停用的仍列出, 只是默认不勾选
    var enabled = true
    /// 落盘用的 slug 基名; nil = 由 name 推导。源端标识(邮箱等)不得进入文件名
    var slugHint: String? = nil
    /// 源端账号标识 (已脱敏); 空 = 源里没给
    var sourceAccount: String = ""
    /// 源侧稳定记录标识 (9router=provider/连接 id, cc-switch=providers.id, cpamp=文件名):
    /// 与 source 组成 origin, 导入去重按它判, 不按显示名
    var sourceRecordId: String = ""

    /// 预览表"授权方式"列
    var authLabel: String { note.lowercased().contains("oauth") ? "OAuth" : "API Key" }

    /// origin 标识 (source + recordId), 写入账号 manifest.origin
    var origin: String { "\(source):\(sourceRecordId)" }
}

enum ProviderImporter {
    static let sqlite = "/usr/bin/sqlite3"

    // MARK: - 9router

    static func from9Router(home: String) -> [ImportCandidate] {
        let db = home + "/.9router/db/data.sqlite"
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        // 全量扫描: isActive 只是 9router 面板的启用开关 (默认 1),
        // 按它过滤会静默丢掉用户停用的账号; 停用与否交给预览列展示, 由用户决定导不导
        let rows = query(db, "select id, provider, authType, name, isActive, data from providerConnections")
        // 源端账号标识 (邮箱/UUID) 按家族编号命名, 原值脱敏后只进说明行
        var seq: [String: Int] = [:]
        func next(_ family: String) -> Int {
            let n = (seq[family] ?? 0) + 1
            seq[family] = n
            return n
        }
        return rows.compactMap { r in
            guard let provider = r["provider"] as? String,
                  let raw = r["data"] as? String,
                  let data = json(raw) else { return nil }
            let label = (r["name"] as? String) ?? provider
            let active = (r["isActive"] as? Int).map { $0 != 0 } ?? true
            let key = (data["apiKey"] as? String) ?? ""
            let authType = (r["authType"] as? String) ?? "apikey"
            /// 显示名 + 落盘 slug: 账号标识型名称一律换成 "家族 账号 N";
            /// 其余用 "家族-slug(label)", 不让中文家族名进文件名
            func naming(_ family: String, _ familySlug: String) -> (name: String, slug: String, account: String) {
                if isAccountId(label) {
                    let n = next(family)
                    return ("\(family) 账号 \(n)", "\(familySlug)-\(n)", maskAccount(label))
                }
                return ("\(family) · \(label)", "\(familySlug)-\(PluginGenerator.slugify(label))", "")
            }
            func cand(_ family: String, _ familySlug: String, template: String?, base: String,
                      proto: String, note: String) -> ImportCandidate {
                let n = naming(family, familySlug)
                return ImportCandidate(source: "9router", name: n.name, template: template, apiKey: key,
                                       baseURL: base, proto: proto, note: note, enabled: active,
                                       slugHint: n.slug, sourceAccount: n.account,
                                       sourceRecordId: (r["id"] as? String) ?? label)
            }
            /// 无法导入的行也要出现, 让用户看见"这条没导"的原因
            func skip(_ reason: String) -> ImportCandidate {
                let n = naming(familyName(provider), PluginGenerator.slugify(provider))
                return ImportCandidate(source: "9router", name: n.name, template: nil,
                                       apiKey: "", baseURL: "", proto: "openai",
                                       note: "\(provider) / \(authType)",
                                       unsupportedReason: reason, enabled: active,
                                       slugHint: n.slug, sourceAccount: n.account,
                                       sourceRecordId: (r["id"] as? String) ?? label)
            }
            switch provider {
            case "glm":
                guard !key.isEmpty else { return skip("源里这条没有 API Key") }
                return cand("GLM", "glm", template: "glm", base: "", proto: "anthropic", note: "glm / apikey")
            case "ollama":
                guard !key.isEmpty else { return skip("源里这条没有 API Key") }
                return cand("Ollama", "ollama", template: "ollama", base: "", proto: "anthropic", note: "ollama / apikey")
            case "opencode-go":
                guard !key.isEmpty else { return skip("源里这条没有 API Key") }
                return cand("OC-Go", "opencode-go", template: "opencode-go", base: "", proto: "openai",
                            note: "opencode-go / apikey")
            case "clinepass":
                guard !key.isEmpty else { return skip("源里这条没有 API Key") }
                return cand("Cline", "cline", template: "cline", base: "", proto: "anthropic", note: "clinepass / apikey")
            default:
                // 通用兼容型: anthropic-compatible-<uuid> / openai-compatible-chat-<uuid>
                guard provider.hasPrefix("anthropic-compatible") || provider.hasPrefix("openai-compatible") else {
                    return skip(authType == "oauth"
                                ? "OAuth 凭证由本机 CLI 管理，请在 TokenHUD 里登录该账号"
                                : "该供应商类型还没有对应模板")
                }
                guard !key.isEmpty, key.hasPrefix("http") == false else {
                    return skip("源里这条没有可用的 API Key")
                }
                let psd = data["providerSpecificData"] as? [String: Any] ?? [:]
                let base = (psd["baseUrl"] as? String) ?? ""
                guard !base.isEmpty else { return skip("源里这条没有填写接口地址") }
                let anthropic = provider.hasPrefix("anthropic")
                return cand(anthropic ? "Anthropic 兼容" : "OpenAI 兼容",
                            anthropic ? "anthropic-compatible" : "openai-compatible",
                            template: nil, base: base, proto: anthropic ? "anthropic" : "openai",
                            note: "\(anthropic ? "anthropic" : "openai")-compatible / apikey")
            }
        }
    }

    /// provider 标识 (codex / zed / ollama-local …) → 给人看的家族名
    private static func familyName(_ provider: String) -> String {
        switch provider {
        case "ollama-local": return "Ollama 本地"
        case "openai-compatible-chat": return "OpenAI 兼容"
        default:
            if provider.hasPrefix("anthropic-compatible") { return "Anthropic 兼容" }
            if provider.hasPrefix("openai-compatible") { return "OpenAI 兼容" }
            return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// 源端账号标识 = 邮箱 / UUID 一类的个人标识, 不得原样进预览或落盘。
    /// 只看"像账号"的形态: 含 @、含 UUID、或有一段 ≥16 位的连续字母数字;
    /// 描述性名称 (localhost-cliproxy 之类) 不算, 否则会误脱敏掉有意义的名字
    static func isAccountId(_ s: String) -> Bool {
        if s.contains("@") { return true }
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if s.range(of: uuid, options: .regularExpression) != nil { return true }
        let longestRun = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(\.count).max() ?? 0
        return longestRun >= 16
    }

    /// ja***@g***.com / qo*** 形式: 保留可辨识前缀, 去掉完整标识
    static func maskAccount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        if s.filter({ $0 == "@" }).count == 1, let at = s.firstIndex(of: "@") {
            let local = s[s.startIndex..<at]
            let parts = s[s.index(after: at)...].split(separator: ".")
            let head = parts.first.map { String($0.prefix(1)) } ?? "*"
            let tld = parts.count > 1 ? String(parts.last!) : "com"
            return "\(local.prefix(2))***@\(head)***.\(tld)"
        }
        return String(s.prefix(2)) + "***"
    }

    // MARK: - cc-switch

    static func fromCCSwitch(home: String) -> [ImportCandidate] {
        let db = home + "/.cc-switch/cc-switch.db"
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let rows = query(db, "select id, app_type, name, settings_config from providers where app_type in ('claude','codex')")
        return rows.compactMap { r in
            guard let app = r["app_type"] as? String,
                  let name = r["name"] as? String,
                  let raw = r["settings_config"] as? String,
                  let cfg = json(raw) else { return nil }
            if app == "claude" {
                let env = cfg["env"] as? [String: Any] ?? [:]
                let base = (env["ANTHROPIC_BASE_URL"] as? String) ?? ""
                let token = ((env["ANTHROPIC_AUTH_TOKEN"] as? String)
                    ?? (env["ANTHROPIC_API_KEY"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                guard !base.isEmpty, !token.isEmpty else { return nil }
                // 占位值 ("\"\"" 之类) 与过短串视为无效凭证
                let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard bare.count >= 8 else { return nil }
                // 名字本身是邮箱/UUID 时脱敏, 且不让它进 slug
                let ident = isAccountId(name)
                return ImportCandidate(source: "cc-switch",
                                       name: ident ? "Claude · \(maskAccount(name))" : name,
                                       template: nil, apiKey: bare,
                                       baseURL: base, proto: "anthropic", note: "claude / \(host(base))",
                                       slugHint: ident ? "claude" : nil,
                                       sourceAccount: ident ? maskAccount(name) : "",
                                       sourceRecordId: (r["id"] as? String) ?? name)
            }
            // codex: OAuth 型, 凭证在 cc-switch 自己的库里, 不导 (TokenHUD 读 ~/.codex)
            return nil
        }
    }

    // MARK: - cpamp (CLIProxyAPI 凭证目录)

    static func fromCPAMP(home: String) -> [ImportCandidate] {
        let dir = home + "/.cli-proxy-api"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".lock") }.compactMap { f in
            let path = dir + "/" + f
            guard let data = FileManager.default.contents(atPath: path), let obj = json(data) else { return nil }
            if (obj["disabled"] as? Bool) == true { return nil }
            let type = (obj["type"] as? String) ?? ""
            let label = (obj["label"] as? String) ?? (obj["email"] as? String) ?? String(f.dropLast(5))
            switch type {
            case "cline-pass", "clinepass":
                let key = (obj["api_key"] as? String) ?? ""
                guard !key.isEmpty else { return nil }
                // label 常回落到 email 字段 → 同样脱敏, 不把账号标识写进预览/文件名
                let ident = isAccountId(label)
                return ImportCandidate(source: "cpamp",
                                       name: ident ? "Cline · \(maskAccount(label))" : "Cline · \(label)",
                                       template: "cline",
                                       apiKey: key, baseURL: "", proto: "anthropic", note: "clinepass",
                                       slugHint: ident ? "cline" : nil,
                                       sourceAccount: ident ? maskAccount(label) : "",
                                       sourceRecordId: f)
            default:
                return nil // codex / antigravity: 本机 CLI 已登录, 由模板直读, 无需导入凭证
            }
        }
    }

    // MARK: - 落库

    /// P1-7 导入事务化: 全部产物 (插件目录 + auth 文件) 先写临时目录, 就绪后一次性移入目标; 任一步失败清临时 (目标零污染)
    @discardableResult
    static func apply(_ c: ImportCandidate, templates: [PluginProvider],
                      userDir: URL, hudDir: URL) throws -> String {
        let slug = uniqueSlug(PluginGenerator.slugify(c.slugHint ?? c.name), userDir: userDir)
        // 同卷临时目录 (rename 原子): userDir 下 .tokenhud-import-<uuid>
        let staging = userDir.appendingPathComponent(".tokenhud-import-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }   // 成功路径已移走, 失败/抛错即清 (幂等)

        // 阶段一: 在 staging 下准备插件目录 (userDir/<slug>) 与 auth (hudDir/.<slug>-usage-auth.json)
        let stagedProviders = staging.appendingPathComponent("providers", isDirectory: true)
        let stagedHud = staging.appendingPathComponent("hud", isDirectory: true)
        try fm.createDirectory(at: stagedProviders, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagedHud, withIntermediateDirectories: true)

        let stagedAuth: URL
        var stagedManifest: ProviderManifest
        if let tslug = c.template, let tmpl = templates.first(where: { $0.slug == tslug }) {
            // instantiate 写 auth 模板到 stagedHud (manifest.authFile 经入参 hudDir 决定)
            stagedManifest = try PluginGenerator.instantiate(template: tmpl, slug: slug, name: c.name,
                                                             into: stagedProviders, hudDir: stagedHud)
            stagedManifest.origin = c.sourceRecordId.isEmpty ? nil : c.origin
            stagedManifest.authFile = PluginGenerator.authPath(slug: slug, hudDir: hudDir)   // manifest 指向目标
            stagedManifest.cacheFile = PluginGenerator.cachePath(slug: slug, hudDir: hudDir)
            try PluginGenerator.writePlugin(slug: slug, manifest: stagedManifest,
                                            script: (try? String(contentsOf: stagedProviders
                                                .appendingPathComponent(slug + "/fetch.sh"), encoding: .utf8)) ?? "",
                                            into: stagedProviders)
            guard stagedManifest.authFile != nil else {
                // 模板无 authFile: 插件目录直接落位 (auth 事务不适用)
                try fm.moveItem(at: stagedProviders.appendingPathComponent(slug),
                                to: userDir.appendingPathComponent(slug))
                return slug
            }
            stagedAuth = PluginGenerator.expandPath(
                PluginGenerator.authPath(slug: slug, hudDir: stagedHud))   // 模板 auth 落在 staging
            var cfg = ProviderConfigStore.read(authFile: stagedAuth, manifest: stagedManifest)
            cfg.refreshKey = c.apiKey
            try ProviderConfigStore.write(cfg, manifest: stagedManifest, to: stagedAuth)
        } else {
            // 通用自定义: baseURL + key, 协议决定触发端点与 header
            var cfg = ProviderConfig()
            cfg.apiBaseURL = c.baseURL
            cfg.refreshKey = c.apiKey
            cfg.refreshProtocol = c.proto
            cfg.refreshUrl = triggerURL(c.baseURL, proto: c.proto)
            cfg.refreshHeader = c.proto == "anthropic"
                ? "Authorization: Bearer <key>\nanthropic-version: 2023-06-01"
                : "Authorization: Bearer <key>"
            let authPath = PluginGenerator.authPath(slug: slug, hudDir: hudDir)   // 直接指向目标
            stagedManifest = PluginGenerator.customManifest(name: c.name, config: cfg, authFile: authPath)
            stagedManifest.origin = c.sourceRecordId.isEmpty ? nil : c.origin
            try PluginGenerator.writePlugin(slug: slug, manifest: stagedManifest,
                                            script: PluginGenerator.oneAPIFetchScript(slug: slug),
                                            into: stagedProviders)
            stagedAuth = PluginGenerator.expandPath(
                PluginGenerator.authPath(slug: slug, hudDir: stagedHud))
            try ProviderConfigStore.createCustom(slug: slug, to: stagedAuth)
            try ProviderConfigStore.write(cfg, manifest: stagedManifest, to: stagedAuth)
        }

        // 阶段二: 全部就绪, 一次性移入 (插件目录 + auth); 目标 auth 已存在 → 冲突失败, 目标零污染
        let finalAuth = PluginGenerator.expandPath(
            PluginGenerator.authPath(slug: slug, hudDir: hudDir))
        try fm.createDirectory(at: finalAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: finalAuth.path) {
            throw NSError(domain: "ProviderImporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "auth 文件已存在: \(finalAuth.lastPathComponent)"])
        }
        let finalPlugin = userDir.appendingPathComponent(slug).standardizedFileURL
        guard finalPlugin.deletingLastPathComponent().standardizedFileURL.path == userDir.standardizedFileURL.path else {
            throw NSError(domain: "ProviderImporter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "账号目录超出应用配置范围"])
        }
        try fm.moveItem(at: stagedProviders.appendingPathComponent(slug), to: finalPlugin)
        do {
            try fm.moveItem(at: stagedAuth, to: finalAuth)
        } catch {
            try fm.moveItem(at: finalPlugin, to: stagedProviders.appendingPathComponent(slug))
            throw error
        }
        return slug
    }

    // MARK: - 工具

    /// sqlite 子进程查询: P1-7 超时真取消 — 5s 内无退出即 terminate() (group.cancelAll 不杀子进程)
    private static func query(_ db: String, _ sql: String) -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sqlite)
        p.arguments = ["-json", db, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe() // 库被占用等错误静默: 该源视为无数据
        guard (try? p.run()) != nil else { return [] }
        // 有界等待: 超时不留孤儿进程 (扫描取消后 sqlite 卡库文件锁也不挂死)
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private static func json(_ s: String) -> [String: Any]? {
        json(Data(s.utf8))
    }

    private static func json(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// baseURL → chat 触发端点 (已含 /v1 或 /messages 则不重复拼)
    private static func triggerURL(_ base: String, proto: String) -> String {
        APIEndpoint.requestURL(baseURL: base, protocolName: proto)
    }

    /// 单测可见入口 (private 逻辑的薄封装)
    static func triggerURLForTest(_ base: String, _ proto: String) -> String { triggerURL(base, proto: proto) }

    private static func uniqueSlug(_ base: String, userDir: URL) -> String {
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: userDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }
}
