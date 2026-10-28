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
}

enum ProviderImporter {
    static let sqlite = "/usr/bin/sqlite3"

    // MARK: - 9router

    static func from9Router(home: String) -> [ImportCandidate] {
        let db = home + "/.9router/db/data.sqlite"
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let rows = query(db, "select provider, authType, name, data from providerConnections where isActive=1")
        return rows.compactMap { r in
            guard let provider = r["provider"] as? String,
                  let raw = r["data"] as? String,
                  let data = json(raw) else { return nil }
            let label = (r["name"] as? String) ?? provider
            let key = (data["apiKey"] as? String) ?? ""
            switch provider {
            case "glm": return ImportCandidate(source: "9router", name: "GLM · \(label)", template: "glm",
                                               apiKey: key, baseURL: "", proto: "anthropic", note: "glm / apikey")
            case "ollama": return ImportCandidate(source: "9router", name: "Ollama · \(label)", template: "ollama",
                                                  apiKey: key, baseURL: "", proto: "anthropic", note: "ollama / apikey")
            case "opencode-go": return ImportCandidate(source: "9router", name: "OC-Go · \(label)", template: "opencode-go",
                                                       apiKey: key, baseURL: "", proto: "openai", note: "opencode-go / apikey")
            case "clinepass": return ImportCandidate(source: "9router", name: "Cline · \(label)", template: "cline",
                                                     apiKey: key, baseURL: "", proto: "anthropic", note: "clinepass / apikey")
            default:
                // 通用兼容型: anthropic-compatible-<uuid> / openai-compatible-chat-<uuid>
                guard provider.hasPrefix("anthropic-compatible") || provider.hasPrefix("openai-compatible"),
                      !key.isEmpty, key.hasPrefix("http") == false else { return nil }
                let psd = data["providerSpecificData"] as? [String: Any] ?? [:]
                let base = (psd["baseUrl"] as? String) ?? ""
                guard !base.isEmpty else { return nil }
                let proto = provider.hasPrefix("anthropic") ? "anthropic" : "openai"
                return ImportCandidate(source: "9router", name: "\(label)", template: nil, apiKey: key,
                                       baseURL: base, proto: proto, note: "\(proto)-compatible / apikey")
            }
        }
    }

    // MARK: - cc-switch

    static func fromCCSwitch(home: String) -> [ImportCandidate] {
        let db = home + "/.cc-switch/cc-switch.db"
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let rows = query(db, "select app_type, name, settings_config from providers where app_type in ('claude','codex')")
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
                return ImportCandidate(source: "cc-switch", name: name, template: nil, apiKey: bare,
                                       baseURL: base, proto: "anthropic", note: "claude / \(host(base))")
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
                return ImportCandidate(source: "cpamp", name: "Cline · \(label)", template: "cline",
                                       apiKey: key, baseURL: "", proto: "anthropic", note: "clinepass")
            default:
                return nil // codex / antigravity: 本机 CLI 已登录, 由模板直读, 无需导入凭证
            }
        }
    }

    // MARK: - 落库

    /// 导入一个候选: 模板型复用 PluginGenerator.instantiate; 通用型生成 one-api 兼容插件
    @discardableResult
    static func apply(_ c: ImportCandidate, templates: [PluginProvider],
                      userDir: URL, hudDir: URL) throws -> String {
        let slug = uniqueSlug(PluginGenerator.slugify(c.name), userDir: userDir)
        if let tslug = c.template, let tmpl = templates.first(where: { $0.slug == tslug }) {
            let manifest = try PluginGenerator.instantiate(template: tmpl, slug: slug, name: c.name,
                                                           into: userDir, hudDir: hudDir)
            guard let af = manifest.authFile.map(expand) else { return slug }
            var cfg = ProviderConfigStore.read(authFile: af, manifest: manifest)
            cfg.queryKey = c.apiKey
            cfg.refreshKey = c.apiKey
            try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
            return slug
        }
        // 通用自定义: baseURL + key, 协议决定触发端点与 header
        var cfg = ProviderConfig()
        cfg.queryUrl = c.baseURL
        cfg.queryKey = c.apiKey
        cfg.refreshKey = c.apiKey
        cfg.refreshProtocol = c.proto
        cfg.refreshUrl = triggerURL(c.baseURL, proto: c.proto)
        cfg.refreshHeader = c.proto == "anthropic"
            ? "Authorization: Bearer <key>\nanthropic-version: 2023-06-01"
            : "Authorization: Bearer <key>"
        let authPath = "~/.claude/hud/.\(slug)-usage-auth.json"
        let manifest = PluginGenerator.customManifest(name: c.name, config: cfg, authFile: authPath)
        try PluginGenerator.writePlugin(slug: slug, manifest: manifest,
                                        script: PluginGenerator.oneAPIFetchScript(slug: slug), into: userDir)
        let af = URL(fileURLWithPath: expand(authPath).path)
        try FileManager.default.createDirectory(at: af.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: af.path) {
            try ProviderConfigStore.createCustom(slug: slug, to: af)
        }
        try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
        return slug
    }

    // MARK: - 工具

    private static func query(_ db: String, _ sql: String) -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sqlite)
        p.arguments = ["-json", db, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe() // 库被占用等错误静默: 该源视为无数据
        guard (try? p.run()) != nil else { return [] }
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

    private static func expand(_ p: String) -> URL {
        p.hasPrefix("~") ? URL(fileURLWithPath: NSHomeDirectory() + String(p.dropFirst()))
                         : URL(fileURLWithPath: p)
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// baseURL → chat 触发端点 (已含 /v1 或 /messages 则不重复拼)
    private static func triggerURL(_ base: String, proto: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        if proto == "anthropic" {
            return b.hasSuffix("/v1") ? b + "/messages" : b + "/v1/messages"
        }
        return b.hasSuffix("/v1") ? b + "/chat/completions" : b + "/v1/chat/completions"
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
