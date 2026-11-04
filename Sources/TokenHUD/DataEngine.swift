import Foundation
import SwiftUI

// MARK: - P1-4 模型调用并发位 (每账号 1 / 全局 2)

/// 模型调用执行位: 满位 acquire 返回 nil (调用方记 skipped busy), 不排队不等待
actor CallSlots {
    private var perAccount: Set<String> = []
    private var globalCount = 0
    let globalLimit: Int

    init(globalLimit: Int = 2) { self.globalLimit = globalLimit }

    /// 占位: 返回 nil = 满位 (同账号占用或全局满)
    func acquire(_ slug: String) -> Bool {
        if perAccount.contains(slug) || globalCount >= globalLimit { return false }
        perAccount.insert(slug)
        globalCount += 1
        return true
    }

    func release(_ slug: String) {
        perAccount.remove(slug)
        globalCount = max(0, globalCount - 1)
    }

    var inFlight: [String] { Array(perAccount) }
}

// MARK: - P1-2 查询 op 体系 (全局 3 / 每账号 1, 同账号合并, 等待总预算 20s)

/// 查询执行位: 同账号进行中 → 后到者附着同 op 共享结果; 满位排队等待 (计入总预算), 超预算抛错
actor QueryGate {
    enum GateError: Error { case waitTimeout }

    private var ops: [String: (revision: Double?, task: Task<UsageCache?, Never>)] = [:]
    private var globalInFlight = 0
    let globalLimit: Int
    let waitBudgetSec: Double

    init(globalLimit: Int = 3, waitBudgetSec: Double = 20) {
        self.globalLimit = globalLimit
        self.waitBudgetSec = waitBudgetSec
    }

    var inFlightSlugs: [String] { Array(ops.keys) }

    /// 执行一次查询 op: 同账号在飞 → 合并共享; 否则占位执行 (满位先等, 等待计入总预算)
    func run(slug: String, revision: Double? = nil,
             _ op: @escaping @Sendable () async -> UsageCache?) async throws -> UsageCache? {
        let deadline = Date().addingTimeInterval(waitBudgetSec)
        while true {
            if let existing = ops[slug], existing.revision == revision {
                return await existing.task.value
            }
            // 同账号旧凭证仍在飞：等它释放，绝不能把旧账号结果交给新 revision。
            if ops[slug] == nil && globalInFlight < globalLimit { break }
            if Date() >= deadline { throw GateError.waitTimeout }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        globalInFlight += 1
        let task = Task { () async -> UsageCache? in
            defer { Task { await self.finish(slug: slug) } }
            return await op()
        }
        ops[slug] = (revision, task)
        return await task.value
    }

    private func finish(slug: String) {
        ops[slug] = nil
        globalInFlight = max(0, globalInFlight - 1)
    }
}

// MARK: - 纯函数

enum HUDFmt {
    enum Color { case red, yellow, green, dim }

    /// >=90 red, >=70 yellow, 其余 green, 无值 dim
    static func pctColor(_ p: Double?) -> Color {
        guard let p else { return .dim }
        if p >= 90 { return .red }
        if p >= 70 { return .yellow }
        return .green
    }

    /// 重置倒计时: 5d3h / 2h13m / 0h45m; 已过期或无值 -> nil
    static func resetCountdown(_ epochSec: Int?, now: Date) -> String? {
        guard let epochSec else { return nil }
        let diff = TimeInterval(epochSec) - now.timeIntervalSince1970
        guard diff > 0 else { return nil }
        let totalMin = Int(diff / 60)
        let h = totalMin / 60, m = totalMin % 60, d = h / 24
        return d > 0 ? "\(d)d\(h % 24)h" : "\(h)h\(m)m"
    }

    /// generatedAt(=最近成功快照时间, 失败不推进) 距 now 未超 interval 秒 — 展示新鲜度/stale 判定用
    static func isFresh(_ cache: UsageCache?, interval: Int, now: Double) -> Bool {
        guard let g = cache?.generatedAt else { return false }
        return now - g < Double(interval) * 1000
    }

    /// 尝试时间 (lastAttemptAt, 旧缓存缺省回退 generatedAt) 距 now 未超 interval 秒 — due/防重刷判定用
    static func isAttemptFresh(_ cache: UsageCache?, interval: Int, now: Double) -> Bool {
        guard let a = cache?.lastAttemptAt ?? cache?.generatedAt else { return false }
        return now - a < Double(interval) * 1000
    }
}

// MARK: - 状态

/// 手动刷新结果 (UI 按此显示真实文案, 不无条件报成功)
enum RefreshOutcome {
    case ok
    case failed(String)
    var ok: Bool { if case .ok = self { return true }; return false }
    /// toast 文案: 成功带家名, 失败带原因
    func message(_ name: String) -> String {
        ok ? "✓ 已刷新 \(name)" : "✗ \(name) 刷新失败: \(reason)"
    }
    var reason: String { if case .failed(let r) = self { return r }; return "" }
}

struct ProviderState: Identifiable {
    let slug: String
    let manifest: ProviderManifest
    var cache: UsageCache?
    var isStale: Bool
    var id: String { slug }

    var worstPct: Double? {
        [cache?.fiveHour?.usedPercentage, cache?.sevenDay?.usedPercentage, cache?.monthly?.usedPercentage]
            .compactMap { $0 }.max()
    }
}

// MARK: - Engine

@MainActor
final class DataEngine: ObservableObject {
    @Published private(set) var states: [ProviderState] = []
    /// 全部插件 (含禁用跟踪的), SettingsView 列表用 — reloadRegistry 时缓存, 免渲染期磁盘扫描
    @Published private(set) var allPlugins: [PluginProvider] = []
    /// 类型模板清单 (bundle providers, 只读) — 添加供应商选类型、EditForm 能力判定用
    @Published private(set) var templates: [PluginProvider] = []
    @Published private(set) var registryErrors: [String: String] = [:]
    private var queryMigrationErrors: [String: String] = [:]
    @Published private(set) var nodeMissing = false
    @Published private(set) var lastRefresh: Date?
    /// "立刻刷新"进行中 (状态栏图标显示 ⟳ 反馈)
    @Published private(set) var isRefreshingAll = false
    /// 图标默认显示哪家 (slug); nil = 全部取最高
    @Published var iconProviderSlug: String?
    /// 关闭用量跟踪的供应商 (slug 集合), UserDefaults 持久化
    @Published private(set) var disabledSlugs: Set<String> = []
    /// 余额不显示到悬浮窗/菜单栏的账号 (slug 集合; 不影响查询) — v0.2 三开关之「悬浮窗显示」
    @Published private(set) var floatingHiddenSlugs: Set<String> = []
    /// 不同步到 Claude Code HUD (envs.json/ACCOUNT_ENVS) 的账号 — v0.2 三开关之「同步 HUD」
    @Published private(set) var hudHiddenSlugs: Set<String> = []
    /// 关闭「定时触发」的供应商 (slug 集合), 与跟踪开关独立
    @Published private(set) var triggerDisabledSlugs: Set<String> = []
    /// 供应商显示顺序 (slug 数组), 空则按字母序
    @Published private(set) var providerOrder: [String] = []
    /// 已删除缺省实例的模板 slug (tombstone: 防迁移复活)
    @Published private(set) var deletedTemplates: Set<String> = []

    private let hudDir: URL
    private let bundleDir: URL?
    private let userDir: URL
    private let runner: ProviderRunner
    private let defaults: UserDefaults
    private let settingsURL: URL
    private var timer: Timer?
    /// P1-4 模型调用并发位 (每账号 1 / 全局 2): 计划触发与测试调用共用
    let callSlots = CallSlots()
    /// P1-2 查询 op 体系: 手动 forceRefresh 与 timer refreshNow 走同一 gate (全局 3/每账号 1/同账号合并)
    let queryGate = QueryGate()

    static let defaultsNodeKey = "tokenhud.nodePath"
    static let defaultsIconKey = "tokenhud.iconProvider"
    static let defaultsDisabledKey = "tokenhud.disabledProviders"
    static let defaultsTriggerDisabledKey = "tokenhud.triggerDisabled.slugs"
    static let defaultsOrderKey = "tokenhud.providerOrder"
    static let defaultsDeletedKey = "tokenhud.deletedTemplates"
    static let defaultsFloatingHiddenKey = "tokenhud.floatingHidden.slugs"
    static let defaultsHudHiddenKey = "tokenhud.hudHidden.slugs"

    init(hudDir: URL, bundleProvidersDir: URL?, userProvidersDir: URL,
         runner: ProviderRunner, defaults: UserDefaults = .standard, settingsURL: URL? = nil) {
        self.hudDir = hudDir
        self.bundleDir = bundleProvidersDir
        self.userDir = userProvidersDir
        self.runner = runner
        self.defaults = defaults
        self.settingsURL = settingsURL ?? URL(fileURLWithPath:
            (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") + "/settings.json")
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
    }

    /// cacheFile 展开: `~` 前缀 -> HOME; 缺省 hudDir/.{slug}-usage-cache.json
    nonisolated static func cachePath(for plugin: PluginProvider, hudDir: URL) -> URL {
        if let cf = plugin.manifest.cacheFile {
            if cf.hasPrefix("~") {
                return URL(fileURLWithPath: NSHomeDirectory() + String(cf.dropFirst()))
            }
            return URL(fileURLWithPath: cf)
        }
        return hudDir.appendingPathComponent(".\(plugin.slug)-usage-cache.json")
    }

    func start() {
        nodeMissing = (runner.nodePath == nil)
        iconProviderSlug = defaults.string(forKey: Self.defaultsIconKey)
        disabledSlugs = Set(defaults.stringArray(forKey: Self.defaultsDisabledKey) ?? [])
        floatingHiddenSlugs = Set(defaults.stringArray(forKey: Self.defaultsFloatingHiddenKey) ?? [])
        hudHiddenSlugs = Set(defaults.stringArray(forKey: Self.defaultsHudHiddenKey) ?? [])
        triggerDisabledSlugs = Set(defaults.stringArray(forKey: Self.defaultsTriggerDisabledKey) ?? [])
        providerOrder = defaults.stringArray(forKey: Self.defaultsOrderKey) ?? []
        deletedTemplates = Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? [])
        // 固化引擎 (mjs) 随 App 分发, 启动覆盖安装 (幂等升级); 再迁移模板缺省实例
        Self.installMjs(bundleDir: bundleDir, hudDir: hudDir)
        migrateAccounts()
        reloadRegistry()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedules()
                await self?.refreshNow()
            }
        }
        Task { await refreshNow() }
    }

    /// 固化脚本安装: bundle 的 mjs/ 目录覆盖安装到 hudDir (App 分发固化引擎, 幂等升级)
    nonisolated static func installMjs(bundleDir: URL?, hudDir: URL) {        guard let bundleDir else { return }
        let srcDir = bundleDir.deletingLastPathComponent().appendingPathComponent("mjs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) else { return }
        let fm = FileManager.default
        for f in files where f.pathExtension == "mjs" {
            let dst = hudDir.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: f, to: dst)
        }
    }

    /// 分发 mjs 脚本 (statusline + provider) 到 hudDir; 供"写入 Claude Code HUD"按钮调用
    func installScripts() {
        Self.installMjs(bundleDir: bundleDir, hudDir: hudDir)
    }

    /// 首启迁移: 每个类型模板若无对应用户实例, 按原 slug 生成缺省实例 (幂等)
    /// auth 文件不覆盖 -> 现有凭证/抓取配置无缝保留
    /// P2-3: 实例已存在 → 字段级 merge — 只补模板新增能力字段, 不全量覆盖
    /// (用户对 manifest 的手改/工具改动保留; displayName 等用户字段一律不动)
    func migrateAccounts() {
        defer { migrateObsoleteQueryCredentials() }
        migrateLegacyCustomAccounts()
        guard let bundleDir else { return }
        let fm = FileManager.default
        for t in ProviderRegistry.scan(dir: bundleDir) {
            if Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? []).contains(t.slug) { continue }
            let dir = userDir.appendingPathComponent(t.slug, isDirectory: true)
            let manifestPath = dir.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: manifestPath.path) {
                Self.mergeManifestCapabilities(template: t.manifest, into: manifestPath)
            } else {
                guard t.manifest.autoCreateDefault ?? true else { continue }
                let instanceAuth = PluginGenerator.expandPath(PluginGenerator.authPath(slug: t.slug, hudDir: hudDir))
                let hadInstanceAuth = fm.fileExists(atPath: instanceAuth.path)
                let legacyAuth = t.manifest.authFile.map {
                    hudDir.appendingPathComponent(PluginGenerator.expandPath($0).lastPathComponent)
                }
                let hadLegacyAuth = legacyAuth.map { fm.fileExists(atPath: $0.path) } ?? false
                do {
                    var manifest = try PluginGenerator.instantiate(template: t, slug: t.slug,
                                                                    name: t.manifest.fullName, into: userDir,
                                                                    hudDir: hudDir)
                    if !hadInstanceAuth, hadLegacyAuth, let legacyAuth {
                        manifest.authFile = legacyAuth.path
                        if let cache = t.manifest.cacheFile {
                            let legacyCache = hudDir.appendingPathComponent(PluginGenerator.expandPath(cache).lastPathComponent)
                            if fm.fileExists(atPath: legacyCache.path) { manifest.cacheFile = legacyCache.path }
                        }
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(manifest).write(to: manifestPath, options: .atomic)
                    }
                    let baseConfig = ProviderConfigStore.read(authFile: instanceAuth, manifest: manifest)
                    let hasAuthSource = baseConfig.authMode == "auth" && (try? ProviderAuthentication.resolveQuota(baseConfig)) != nil
                    if !hadInstanceAuth && !hadLegacyAuth && t.manifest.authStyle != "local" && !hasAuthSource {
                        disabledSlugs.insert(t.slug)
                        triggerDisabledSlugs.insert(t.slug)
                        defaults.set(Array(disabledSlugs), forKey: Self.defaultsDisabledKey)
                        defaults.set(Array(triggerDisabledSlugs), forKey: Self.defaultsTriggerDisabledKey)
                    }
                } catch {
                    registryErrors[t.slug] = "账号迁移失败：\(error.localizedDescription)"
                }
            }
        }
        upgradeTemplateAccounts()
    }

    /// Upgrade only app-owned account files; external CLI authorization and caches stay read-only.
    private func migrateObsoleteQueryCredentials() {
        let fm = FileManager.default
        queryMigrationErrors = [:]
        for plugin in ProviderRegistry.scan(dir: userDir) {
            let auth = plugin.manifest.authFile.map(PluginGenerator.expandPath)
                ?? hudDir.appendingPathComponent(".\(plugin.slug)-usage-auth.json")
            do {
                guard try isOwnedRegularUsageFile(auth, kind: "auth"),
                      ProviderConfigStore.hasObsoleteQueryCredentials(authFile: auth, manifest: plugin.manifest) else { continue }
                let config = ProviderConfigStore.read(authFile: auth, manifest: plugin.manifest)
                if let source = ProviderAuthentication.credentialFileURL(for: config),
                   source.resolvingSymlinksInPath() == auth.standardizedFileURL.resolvingSymlinksInPath() { continue }
                let cache = Self.cachePath(for: plugin, hudDir: hudDir)
                // Remove the previous identity's cache before committing the new inherited identity.
                if fm.fileExists(atPath: cache.path) {
                    guard try isOwnedRegularUsageFile(cache, kind: "cache") else {
                        throw ProviderAuthenticationError(message: "旧查询缓存不属于可自动清理的账号文件，请检查缓存路径")
                    }
                    try fm.removeItem(at: cache)
                }
                invalidateSnapshot(plugin.slug)
                try ProviderConfigStore.write(config, manifest: plugin.manifest, to: auth)
            } catch {
                let message = "查询认证迁移失败：\(error.localizedDescription)"
                queryMigrationErrors[plugin.slug] = message
                registryErrors[plugin.slug] = message
            }
        }
    }

    private func isOwnedRegularUsageFile(_ file: URL, kind: String) throws -> Bool {
        let standardized = file.standardizedFileURL
        guard standardized.deletingLastPathComponent() == hudDir.standardizedFileURL,
              standardized.resolvingSymlinksInPath().deletingLastPathComponent() == hudDir.resolvingSymlinksInPath(),
              standardized.lastPathComponent.hasSuffix("-usage-\(kind).json")
                || standardized.lastPathComponent.hasSuffix(".usage-\(kind).json") else { return false }
        guard FileManager.default.fileExists(atPath: standardized.path) else { return false }
        return try FileManager.default.attributesOfItem(atPath: standardized.path)[.type] as? FileAttributeType == .typeRegular
    }

    private func upgradeTemplateAccounts() {
        guard let bundleDir else { return }
        let templates = ProviderRegistry.scan(dir: bundleDir)
        for plugin in ProviderRegistry.scan(dir: userDir) {
            guard let type = plugin.manifest.template,
                  let template = templates.first(where: { $0.slug == type }) else { continue }
            let scriptURL = plugin.dir.appendingPathComponent("fetch.sh")
            if let oldScript = try? String(contentsOf: scriptURL, encoding: .utf8),
               oldScript.contains("# TokenHUD 模板:"),
               let source = try? String(contentsOf: template.dir.appendingPathComponent("fetch.sh"), encoding: .utf8) {
                let current = source.replacingOccurrences(of: "{SLUG}", with: plugin.slug)
                if oldScript != current { try? current.write(to: scriptURL, atomically: true, encoding: .utf8) }
            }
            Self.mergeManifestCapabilities(template: template.manifest,
                                           into: plugin.dir.appendingPathComponent("manifest.json"))
        }
    }

    /// 仅迁移旧版自动生成的 billing 脚本；用户自己编写的插件不改动。
    func migrateLegacyCustomAccounts() {
        let fm = FileManager.default
        for plugin in ProviderRegistry.scan(dir: userDir) {
            guard plugin.manifest.template == nil, plugin.manifest.quotaMode == nil else { continue }
            let scriptURL = plugin.dir.appendingPathComponent(plugin.manifest.fetch)
            let manifestURL = plugin.dir.appendingPathComponent("manifest.json")
            let auth = plugin.manifest.authFile.map(PluginGenerator.expandPath)
                ?? hudDir.appendingPathComponent(".\(plugin.slug)-usage-auth.json")
            guard scriptURL.standardizedFileURL == plugin.dir.appendingPathComponent("fetch.sh").standardizedFileURL,
                  scriptURL.resolvingSymlinksInPath().deletingLastPathComponent().path == plugin.dir.resolvingSymlinksInPath().path,
                  auth.lastPathComponent == ".\(plugin.slug)-usage-auth.json",
                  auth.resolvingSymlinksInPath().deletingLastPathComponent().path == hudDir.resolvingSymlinksInPath().path,
                  let script = try? String(contentsOf: scriptURL, encoding: .utf8),
                  script.contains("# TokenHUD 生成: one-api"), script.contains("billing/subscription"),
                  let originalManifest = try? Data(contentsOf: manifestURL),
                  let originalAuth = try? Data(contentsOf: auth) else { continue }
            var config = ProviderConfigStore.read(authFile: auth, manifest: plugin.manifest)
            let legacyAuth = (try? JSONSerialization.jsonObject(with: originalAuth)) as? [String: Any]
            let storedBase = (legacyAuth?["apiUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !storedBase.isEmpty { config.apiBaseURL = storedBase }
            else if let base = plugin.manifest.queryUrl, !base.isEmpty { config.apiBaseURL = base }
            config.queryUrl = ""
            config.quotaMode = "none"
            var manifest = plugin.manifest
            manifest.queryUrl = nil
            manifest.quotaMode = "none"
            do {
                try ProviderConfigStore.write(config, manifest: manifest, to: auth)
                try PluginGenerator.writePlugin(slug: plugin.slug, manifest: manifest,
                                                script: PluginGenerator.oneAPIFetchScript(slug: plugin.slug), into: userDir)
            } catch {
                // 保存失败恢复原始三份文件，避免半迁移改变模型调用配置。
                try? originalAuth.write(to: auth, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
                try? originalManifest.write(to: manifestURL, options: .atomic)
                try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
                registryErrors[plugin.slug] = "旧账号迁移失败：\(error.localizedDescription)"
            }
        }
    }

    /// 模板升级同步 (字段级): 缺失能力字段按模板补齐；refreshHeader 仅追加缺失名称，已有值不动
    /// 补齐范围 = 协议/能力字段 (testModel/testPrompt/queryUrl/queryAuth/queryKeyField/
    /// refreshUrl/refreshProtocol/refreshAuth/refreshHeader/needsCredential/buckets/accent/icon/intervalSec)
    /// 身份/用户字段 (displayName/enabled/authMode/origin) 不在补齐范围
    nonisolated static func mergeManifestCapabilities(template: ProviderManifest, into manifestPath: URL) {
        guard let data = try? Data(contentsOf: manifestPath),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tmplData = try? JSONEncoder().encode(template),
              let tmpl = try? JSONSerialization.jsonObject(with: tmplData) as? [String: Any]
        else { return }
        let mergeKeys = ["testModel", "testPrompt", "queryUrl", "queryAuth", "queryKeyField",
                         "refreshUrl", "refreshProtocol", "refreshAuth", "refreshHeader",
                         "needsCredential", "buckets", "accent", "icon", "intervalSec",
                         "credentialSource", "authCallUrl", "authCallProtocol", "authCallHeader", "authModelsUrl",
                         "inheritQueryUrl", "inheritQueryHeader", "quotaAuthModes"]
        var changed = false
        // v1 GLM 模板误把网页登录 token 声明成 bearer；仅修正已知旧声明。
        if template.queryAuth == "jwt", obj["queryAuth"] as? String == "bearer" {
            obj["queryAuth"] = "jwt"
            changed = true
        }
        if obj["template"] != nil, obj["quotaMode"] == nil {
            obj["quotaMode"] = "script"
            changed = true
        }
        for k in mergeKeys where obj[k] == nil {
            if let v = tmpl[k] { obj[k] = v; changed = true }
        }
        if var source = obj["credentialSource"] as? [String: Any],
           let declared = tmpl["credentialSource"] as? [String: Any] {
            for key in ["alternatives", "contextPaths"] where source[key] == nil {
                if let value = declared[key] { source[key] = value; changed = true }
            }
            obj["credentialSource"] = source
        }
        // Header 模板按名称补新增声明，已有值（含用户自定义认证）始终保留。
        if let existing = obj["refreshHeader"] as? String, let declared = template.refreshHeader {
            func headerName(_ line: Substring) -> String? {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                return name.isEmpty ? nil : name
            }
            var names = Set(existing.split(separator: "\n").compactMap(headerName))
            var additions: [String] = []
            for line in declared.split(separator: "\n") {
                if let name = headerName(line), names.insert(name).inserted {
                    additions.append(String(line))
                }
            }
            if !additions.isEmpty {
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                obj["refreshHeader"] = existing + separator + additions.joined(separator: "\n")
                changed = true
            }
        }
        guard changed else { return }
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: manifestPath, options: .atomic)
        }
    }

    /// 定时触发: 到点发 chat 请求触发滚动计费窗口
    /// 触发去重键 = slug + 本地日期(yyyy-MM-dd) + HH:MM, 持久 UserDefaults:
    /// 跨重启不重复消费 (旧内存键重启清零会重发), 跨天不误杀 (键含日期, 次日同时刻是不同键)
    private var lastScheduledTrigger: [String: String] = [:]
    /// scheduleTimes 缓存 (reloadRegistry 时重建, 免每 10s 重复读 auth 文件)
    private var cachedSchedules: [(slug: String, manifest: ProviderManifest, authFile: URL, times: [String])] = []

    nonisolated static let defaultsScheduleFiredKey = "tokenhud.scheduleFired"

    /// 本地日期键 (yyyy-MM-dd): DST/时区变化自然落在日期串里
    nonisolated static func scheduleKey(slug: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: date))|\(slug)"
    }

    private func loadFiredSchedules() -> [String: [String: String]] {
        guard let raw = defaults.string(forKey: Self.defaultsScheduleFiredKey),
              let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func saveFiredSchedules(_ dict: [String: [String: String]]) {
        guard let data = try? JSONEncoder().encode(dict),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: Self.defaultsScheduleFiredKey)
    }

    /// P1-4: skipped 记录与 fired 同仓同 schema (值域加 "skipped:<reason>"), nonisolated 供 Task 内读
    nonisolated static func loadSkipped(defaults: UserDefaults) -> [String: [String: String]] {
        guard let raw = defaults.string(forKey: defaultsScheduleFiredKey),
              let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    nonisolated static func saveSkipped(_ dict: [String: [String: String]], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(dict),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: defaultsScheduleFiredKey)
    }

    func checkSchedules(now: Date = Date(),
                        trigger: @escaping (ProviderManifest, URL) async -> String? = { manifest, authFile in
                            await RefreshTrigger.trigger(manifest: manifest, authFile: authFile)
                        }) {
        let cal = Calendar.current
        let hhmm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        var fired = loadFiredSchedules()
        // 只保留今天与昨天的键 (防字典无限增长; 昨天保留兜 DST 深夜场景)
        let todayPrefix = Self.dayPrefix(now), yesterdayPrefix = Self.dayPrefix(cal.date(byAdding: .day, value: -1, to: now) ?? now)
        fired = fired.filter { k, _ in k.hasPrefix(todayPrefix) || k.hasPrefix(yesterdayPrefix) }
        for sch in cachedSchedules {
            guard sch.times.contains(hhmm) else { continue }
            guard !disabledSlugs.contains(sch.slug),
                  !triggerDisabledSlugs.contains(sch.slug) else { continue } // 停用账号不触发，保留计划偏好
            // 持久去重: 同 slug 同本地日 同 HH:MM 只触发一次 (跨重启/跨天均正确, 键含日期)
            let before = fired
            guard Self.markScheduleFired(fired: &fired, slug: sch.slug, hhmm: hhmm, date: now) else { continue }
            saveFiredSchedules(fired)
            _ = before
            lastScheduledTrigger[sch.slug] = hhmm
            // P1-4 并发位: 每账号 1 / 全局 2; 满位记 skipped busy (持久 reason 字段, 复用调度去重存储)
            Task { @MainActor [slots = callSlots] in
                guard await slots.acquire(sch.slug) else {
                    var f = await Self.loadSkipped(defaults: defaults)
                    f[Self.scheduleDedupKey(slug: sch.slug, date: Date()), default: [:]][hhmm] = "skipped:busy"
                    await Self.saveSkipped(f, defaults: defaults)
                    return
                }
                defer { Task { await slots.release(sch.slug) } }
                guard !disabledSlugs.contains(sch.slug),
                      !triggerDisabledSlugs.contains(sch.slug),
                      cachedSchedules.contains(where: {
                          $0.slug == sch.slug && $0.times.contains(hhmm)
                              && $0.manifest.refreshUrl == sch.manifest.refreshUrl
                              && $0.authFile == sch.authFile
                      }) else {
                    var f = Self.loadSkipped(defaults: defaults)
                    f[Self.scheduleDedupKey(slug: sch.slug, date: now), default: [:]][hhmm] = "skipped:disabled"
                    Self.saveSkipped(f, defaults: defaults)
                    return
                }
                let callRevision = Self.configRevision(slug: sch.slug, manifest: sch.manifest)
                let response = await trigger(sch.manifest, sch.authFile)
                let outcome = response?.hasPrefix("✓") == true ? "succeeded"
                    : (response?.contains("结果不确定") == true ? "uncertain" : "failed")
                var completed = loadFiredSchedules()
                completed[Self.scheduleDedupKey(slug: sch.slug, date: now), default: [:]][hhmm] = outcome
                saveFiredSchedules(completed)
                if outcome == "succeeded", Self.canQuery(sch.manifest),
                   ProviderConfigStore.read(authFile: sch.authFile, manifest: sch.manifest).quotaMode != "none" {
                    Task { @MainActor [weak self] in
                        guard let self, self.allPlugins.contains(where: { $0.slug == sch.slug }),
                              Self.configRevision(slug: sch.slug, manifest: sch.manifest) == callRevision else { return }
                        _ = await self.forceRefresh(slug: sch.slug)
                    }
                }
            }
        }
    }

    /// 日期串前缀 (清理用): "yyyy-MM-dd|"
    nonisolated private static func dayPrefix(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d) + "|"
    }

    /// auth 文件路径: manifest.authFile 展开, 缺省 hudDir/.{slug}-usage-auth.json
    private func authURL(for st: ProviderState) -> URL? {
        if let af = st.manifest.authFile {
            if af.hasPrefix("~") { return URL(fileURLWithPath: NSHomeDirectory() + String(af.dropFirst())) }
            return URL(fileURLWithPath: af)
        }
        return hudDir.appendingPathComponent(".\(st.slug)-usage-auth.json")
    }

    func reloadRegistry() {
        var (plugins, errors) = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir)
        // 已删缺省实例的模板: bundle 源仍在但不再显示 (tombstone 挡迁移也挡列表)
        let deleted = Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? [])
        if !deleted.isEmpty {
            let fm = FileManager.default
            plugins = plugins.filter { p in
                let hasInstance = fm.fileExists(atPath: userDir
                    .appendingPathComponent(p.slug, isDirectory: true)
                    .appendingPathComponent("manifest.json").path)
                return hasInstance || !deleted.contains(p.slug)
            }
        }
        registryErrors = errors.merging(queryMigrationErrors) { _, migration in migration }
        allPlugins = plugins.sorted {
            let left = orderIndex($0.slug), right = orderIndex($1.slug)
            return left == right ? $0.slug < $1.slug : left < right
        }
        // 类型模板 = bundle 里的只读定义 (添加供应商选类型/编辑能力判定用)
        templates = bundleDir.map { ProviderRegistry.scan(dir: $0) } ?? []
        // scheduleTimes 缓存重建 (编辑保存后 reload 即刷新)
        cachedSchedules = plugins.compactMap { p in
            let auth = authURL(for: ProviderState(slug: p.slug, manifest: p.manifest, cache: nil, isStale: false))
            guard let auth else { return nil }
            return (p.slug, p.manifest, auth, ProviderConfigStore.read(authFile: auth, manifest: p.manifest).scheduleTimes)
        }
        let now = Date().timeIntervalSince1970 * 1000
        // v0.2: 间隔取每账号覆盖 (UserDefaults) 优先, 缺省 manifest.interval
        states = plugins
            .filter { $0.manifest.isEnabled && !disabledSlugs.contains($0.slug) }
            .sorted { orderIndex($0.slug) < orderIndex($1.slug) }
            .map {
                let cache = readCache(slug: $0.slug, manifest: $0.manifest)
                let interval = defaults.integer(forKey: Self.intervalKey($0.slug)) > 0
                    ? defaults.integer(forKey: Self.intervalKey($0.slug)) * 60 : $0.manifest.interval
                return ProviderState(slug: $0.slug, manifest: $0.manifest, cache: cache,
                                     isStale: !HUDFmt.isFresh(cache, interval: interval, now: now))
            }
        // 图标指向的家若已不存在, 回退到全部取最高
        if let slug = iconProviderSlug, !states.contains(where: { $0.slug == slug }) {
            iconProviderSlug = nil
        }
    }

    /// 按 slug 查类型模板 (EditForm 能力判定用)
    func template(bySlug slug: String) -> PluginProvider? {
        templates.first { $0.slug == slug }
    }

    /// 开关某家用量跟踪; 关闭后该家从 states 移除, 不再 fetch
    func setTracking(_ slug: String, enabled: Bool) {
        if enabled {
            disabledSlugs.remove(slug)
        } else {
            disabledSlugs.insert(slug)
        }
        defaults.set(Array(disabledSlugs), forKey: Self.defaultsDisabledKey)
        reloadRegistry()
    }

    /// v0.2 「悬浮窗显示」: 只影响悬浮窗/菜单栏展示, 不影响查询与调度
    func setFloatingHidden(_ slug: String, hidden: Bool) {
        if hidden { floatingHiddenSlugs.insert(slug) } else { floatingHiddenSlugs.remove(slug) }
        defaults.set(Array(floatingHiddenSlugs), forKey: Self.defaultsFloatingHiddenKey)
    }

    /// 「同步 HUD」不影响查询；同步失败时保留原开关状态并返回错误。
    @discardableResult
    func setHudHidden(_ slug: String, hidden: Bool) -> Result<Void, Error> {
        let previous = hudHiddenSlugs
        if hidden { hudHiddenSlugs.insert(slug) } else { hudHiddenSlugs.remove(slug) }
        let result = writeEnvsForHudSync()
        switch result {
        case .success:
            defaults.set(Array(hudHiddenSlugs), forKey: Self.defaultsHudHiddenKey)
        case .failure:
            hudHiddenSlugs = previous
        }
        return result
    }

    /// 清理已删除账号的开关偏好，不修改 HUD；调用方在刷新账号列表后另行同步。
    func forgetAccountSettings(_ slug: String) {
        disabledSlugs.remove(slug)
        floatingHiddenSlugs.remove(slug)
        hudHiddenSlugs.remove(slug)
        triggerDisabledSlugs.remove(slug)
        defaults.set(Array(disabledSlugs), forKey: Self.defaultsDisabledKey)
        defaults.set(Array(floatingHiddenSlugs), forKey: Self.defaultsFloatingHiddenKey)
        defaults.set(Array(hudHiddenSlugs), forKey: Self.defaultsHudHiddenKey)
        defaults.set(Array(triggerDisabledSlugs), forKey: Self.defaultsTriggerDisabledKey)
        defaults.removeObject(forKey: Self.intervalKey(slug))
    }

    // MARK: v0.2 每账号查询间隔覆盖 (UserDefaults; 缺省用 manifest.interval)

    nonisolated static func intervalKey(_ slug: String) -> String { "tokenhud.interval.\(slug)" }

    /// 是否为该账号设置了独立的查询间隔。
    func hasIntervalOverride(_ slug: String) -> Bool {
        defaults.object(forKey: Self.intervalKey(slug)) != nil
    }

    /// 有效间隔 (分钟): 覆盖值优先, 否则 manifest (秒→分)
    func effectiveIntervalMinutes(_ slug: String, manifest: ProviderManifest) -> Int {
        let saved = defaults.integer(forKey: Self.intervalKey(slug))
        return saved > 0 ? saved : max(1, manifest.interval / 60)
    }

    func setIntervalMinutes(_ slug: String, minutes: Int) {
        let clamped = max(1, min(1440, minutes))
        defaults.set(clamped, forKey: Self.intervalKey(slug))
        reloadRegistry()   // isStale 按 f际间隔重算
    }

    func clearIntervalOverride(_ slug: String) {
        defaults.removeObject(forKey: Self.intervalKey(slug))
        reloadRegistry()
    }

    /// v0.2 ACCOUNT_ENVS 键 = 全部启用且未停用且未关同步的账号 (**含内置**: registry 硬编码靠它取键)
    var hudSyncNames: [String] {
        allPlugins
            .filter { $0.manifest.isEnabled && !disabledSlugs.contains($0.slug) && !hudHiddenSlugs.contains($0.slug) }
            .map(HUDSync.accountKey)
    }

    /// 每个已选账号均有动态缓存条目，类型模板不再决定 HUD 身份。
    var envsEntryNames: [String] {
        hudSyncNames
    }

    /// 同步账号投影到 HUD，保留不属于本应用的条目；失败反馈给用户界面。
    @discardableResult
    func writeEnvsForHudSync(removingManagedNames: Set<String> = []) -> Result<Void, Error> {
        do {
            try HUDSync.sync(plugins: allPlugins, hiddenSlugs: hudHiddenSlugs,
                             disabledSlugs: disabledSlugs, removingManagedNames: removingManagedNames,
                             hudDir: hudDir, settingsURL: settingsURL)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 开关某家「定时触发」; 与用量跟踪独立 (跟踪关 ≠ 定时关)
    func setTriggerEnabled(_ slug: String, enabled: Bool) {
        if enabled {
            triggerDisabledSlugs.remove(slug)
        } else {
            triggerDisabledSlugs.insert(slug)
        }
        defaults.set(Array(triggerDisabledSlugs), forKey: Self.defaultsTriggerDisabledKey)
    }

    /// 设置图标默认显示哪家; nil = 全部取最高
    func setIconProvider(_ slug: String?) {
        iconProviderSlug = slug
        defaults.set(slug, forKey: Self.defaultsIconKey)
    }

    /// 设置供应商显示顺序 (slug 数组); 影响 states 顺序
    func setProviderOrder(_ order: [String]) {
        providerOrder = order
        defaults.set(order, forKey: Self.defaultsOrderKey)
        reloadRegistry()
    }

    /// 删除缺省模板实例时记 tombstone (迁移不再复活该类型缺省账号)
    func markTemplateDeleted(_ slug: String) {
        var deleted = Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? [])
        deleted.insert(slug)
        defaults.set(Array(deleted), forKey: Self.defaultsDeletedKey)
        deletedTemplates = deleted
    }

    /// 排序权重: 在 order 中靠前则小; 未列出则排最后 (保持字母序)
    private func orderIndex(_ slug: String) -> Int {
        if let i = providerOrder.firstIndex(of: slug) { return i }
        return providerOrder.count // 未列出, 排最后
    }

    /// nil 是旧自有 fetch 插件的兼容契约；新账号必须显式声明 endpoint 或 none。
    nonisolated static func canQuery(_ manifest: ProviderManifest) -> Bool {
        switch manifest.quotaMode {
        case "none": return false
        case "script": return true
        case "endpoint": return !(manifest.queryUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case nil: return true
        default: return false
        }
    }

    func refreshNow() async {
        for index in states.indices {
            if let cache = states[index].cache,
               !cacheMatchesAuthSource(cache, slug: states[index].slug, manifest: states[index].manifest) {
                states[index].cache = nil
                states[index].isStale = true
            }
        }
        let now = Date().timeIntervalSince1970 * 1000
        // P1-3 退避: ratelimit 暂停窗口内的账号跳过本轮自动查询 (到期自动恢复; 手动 forceRefresh 不受限)
        let paused = Self.loadPaused(defaults: defaults)
        // MainActor 上下文先筛过期家 (按尝试时间: 失败也会前移 lastAttemptAt, 免 10s timer 对失败家反复重刷)
        // v0.2: 间隔取每账号覆盖优先 (秒), 缺省 manifest.interval
        let due: [(String, PluginProvider)] = states.compactMap { st in
            guard Self.canQuery(st.manifest), paused[st.slug] == nil else { return nil }
            if st.manifest.quotaMode != nil {
                guard let auth = authURL(for: st) else { return nil }
                let config = ProviderConfigStore.read(authFile: auth, manifest: st.manifest)
                guard config.quotaMode != "none" else { return nil }
                let ready = (try? ProviderAuthentication.resolveQuota(config)) != nil
                guard ready else { return nil }
            }
            let override = defaults.integer(forKey: Self.intervalKey(st.slug))
            let interval = override > 0 ? override * 60 : st.manifest.interval
            guard !HUDFmt.isAttemptFresh(st.cache, interval: interval, now: now) else { return nil }
            return (st.slug, PluginProvider(slug: st.slug, manifest: st.manifest,
                                            dir: pluginDir(slug: st.slug)))
        }
        guard !due.isEmpty else {
            return // 无家过期, 不更新 lastRefresh (避免假"0s前")
        }
        await fetch(due, now: now)
    }

    /// 强制刷新单家 (忽略 fresh 状态), 用于"刷新额度"后立即查余额更新
    /// 停用跟踪的账号同样允许手动查询 (查询不消费额度), 结果写缓存不进 states
    /// (迟到回包核对在 states 内提交路径上由 fetch 负责; 此路径的提交即用户当前所见, 不需要 revision 挡)
    @discardableResult
    func forceRefresh(slug: String) async -> RefreshOutcome {
        let plugin = allPlugins.first { $0.slug == slug }
            ?? states.first { $0.slug == slug }.map {
                PluginProvider(slug: $0.slug, manifest: $0.manifest, dir: pluginDir(slug: $0.slug))
            }
        guard let plugin else { return .failed("供应商不存在") }
        guard Self.canQuery(plugin.manifest) else { return .failed("该账号未配置额度查询") }
        // 核对: 查询期间账号被删/凭证被改 → 丢弃 (FR-05.3)
        let rev0 = Self.configRevision(slug: slug, manifest: plugin.manifest)
        let now = Date().timeIntervalSince1970 * 1000
        // P1-2: 查询 op 走统一 gate (同账号在飞 → 合并共享结果; 满位等待计入 20s 总预算)
        let fetched: UsageCache?
        do {
            fetched = try await queryGate.run(slug: slug, revision: rev0) { [runner] in await runner.run(plugin) }
        } catch {
            return .failed(Self.reason(for: "busy"))
        }
        guard let p = allPlugins.first(where: { $0.slug == slug }),
              Self.configRevision(slug: slug, manifest: p.manifest) == rev0 else {
            return .failed("查询期间配置已变更，结果已丢弃")
        }
        // 失败 (nil) 也走 apply: 记录 lastAttemptAt/stale (失败不推进 generatedAt)
        if states.contains(where: { $0.slug == slug }) {
            apply(slug: slug, fetched: fetched, now: now)
        } else if let fetched {
            writeCache(fetched, plugin: ProviderState(slug: slug, manifest: plugin.manifest,
                                                      cache: nil, isStale: false))
        }
        lastRefresh = Date()
        guard let fetched else { return .failed("查询无结果") }
        if let e = fetched.error { return .failed(Self.reason(for: e)) }
        return .ok
    }

    /// 迟到回包核对: 发起时快照 revision, 提交前 slug 仍在 allPlugins 且 revision 未变 (FR-05.3)
    /// P1-2: 每 op 经 QueryGate (全局 3/每账号 1/同账号合并), 满位等待计入总预算, 超时标 busy
    private func fetch(_ due: [(String, PluginProvider)], now: Double, checkRevision: Bool) async {
        let revisions: [String: Double] = checkRevision
            ? Dictionary(uniqueKeysWithValues: due.map { ($0.0, Self.configRevision(slug: $0.0, manifest: $0.1.manifest)) })
            : [:]
        let results: [(String, UsageCache?)] = await withTaskGroup(of: (String, UsageCache?).self) { group in
            for (slug, plugin) in due {
                group.addTask { [gate = queryGate, runner] in
                    // gate 抛超时 → 记 busy (该家本轮未查, 不误标 fetch 失败)
                    let cache = try? await gate.run(slug: slug, revision: revisions[slug]) { await runner.run(plugin) }
                    return (slug, cache ?? nil)
                }
            }
            var acc: [(String, UsageCache?)] = []
            for await r in group { acc.append(r) }
            return acc
        }
        for (slug, cache) in results {
            // 版本核对: 查询期间账号被删 (slug 不在 allPlugins) 或凭证被改 (revision 变) → 丢弃, 不污染新状态
            if checkRevision {
                guard let p = allPlugins.first(where: { $0.slug == slug }),
                      revisions[slug] == Self.configRevision(slug: slug, manifest: p.manifest) else {
                    print("[DataEngine] discard late result for \(slug) (config changed or removed)")
                    continue
                }
            }
            apply(slug: slug, fetched: cache, now: now)
        }
        lastRefresh = Date()
    }

    /// 配置版本: auth 文件 mtime (epoch 秒); 文件缺失 = 0。最简可用, 凭证/时间点变更都会反映
    nonisolated static func configRevision(slug: String, manifest: ProviderManifest) -> Double {
        let path: URL
        if let af = manifest.authFile {
            path = af.hasPrefix("~")
                ? URL(fileURLWithPath: NSHomeDirectory() + String(af.dropFirst()))
                : URL(fileURLWithPath: af)
        } else {
            path = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/hud/.\(slug)-usage-auth.json")
        }
        let ownRevision = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let config = ProviderConfigStore.read(authFile: path, manifest: manifest)
        guard config.authMode == "auth", let source = ProviderAuthentication.credentialFileURL(for: config) else {
            return ownRevision
        }
        let sourceRevision = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return ownRevision + sourceRevision
    }

    /// 错误码 → 人话 (缓存契约里的 error 字段值不变)
    nonisolated static func reason(for code: String) -> String {
        switch code {
        case "auth", "no-auth": return "缺凭证或凭证失效"
        case "fetch": return "查询无结果"
        case "ratelimit": return "触发限频（429），稍后自动恢复"
        case "busy": return "查询排队超时（并发已满），请稍后重试"
        default: return code
        }
    }

    /// 刷新余额: 只强制查余额 (不 POST chat, 不消费额度) — 菜单栏/面板/悬浮窗"刷新余额"入口
    /// (FR-08.5 快览默认查询不调用模型; 触发型动作只保留在设置中心账号详情的显式"发送测试调用")
    func refreshBalancesOnly() async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        await withTaskGroup(of: Void.self) { group in
            for st in states {
                group.addTask { [weak self, slug = st.slug] in
                    _ = await self?.forceRefresh(slug: slug)
                }
            }
        }
    }

    // MARK: P1-3 429 退避: error=ratelimit → 该账号暂停自动查询至 max(interval, 60s), 到期自动恢复

    /// 暂停截止时间戳 (epoch ms, slug → deadline); 内存 + UserDefaults (跨重启保持)
    nonisolated static let defaultsRateLimitPausedKey = "tokenhud.ratelimit.pausedUntil"

    nonisolated static func loadPaused(defaults: UserDefaults) -> [String: Double] {
        guard let raw = defaults.string(forKey: defaultsRateLimitPausedKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return dict.filter { $0.value > Date().timeIntervalSince1970 * 1000 } // 过期条目即剔除
    }

    nonisolated static func savePaused(_ dict: [String: Double], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(dict),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: defaultsRateLimitPausedKey)
    }

    /// 暂停窗口: error=ratelimit → max(interval, 60s) 秒 (纯函数, 可测)
    nonisolated static func rateLimitPauseMs(intervalSec: Int) -> Double {
        Double(max(intervalSec, 60)) * 1000
    }

    /// 触发滚动窗口并刷新: 对全部启用供应商发 chat 请求触发额度计算, 再强制查余额+重置时间
    /// 仅显式入口使用 (消费额度); 不再挂在菜单栏/悬浮窗快捷刷新上
    func triggerAndRefreshAll() async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        // 并行触发滚动窗口
        await withTaskGroup(of: Void.self) { group in
            for st in states {
                guard let authFile = authURL(for: st) else { continue }
                group.addTask {
                    _ = await RefreshTrigger.trigger(manifest: st.manifest, authFile: authFile)
                }
            }
        }
        // 宽限 2s: 供应商计费多为异步结算, 立查可能读到旧值
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // 并行强制查余额
        await withTaskGroup(of: Void.self) { group in
            for st in states {
                group.addTask { [weak self, slug = st.slug] in
                    _ = await self?.forceRefresh(slug: slug)
                }
            }
        }
    }

    /// 并行刷给定家, 结果收齐后回 MainActor 统一落盘/更新内存态 (迟到回包按 configRevision 核对丢弃)
    private func fetch(_ due: [(String, PluginProvider)], now: Double) async {
        await fetch(due, now: now, checkRevision: true)
    }

    /// 测试注入口 (private 逻辑的薄封装)
    var runnerForTest: ProviderRunner { runner }
    /// v0.2 全局设置页诊断: node 路径 (nil = 未找到)
    var nodePathForUI: String? { runner.nodePath }
    func applyForTest(slug: String, fetched: UsageCache?, now: Double, checkRevision: Bool) {
        guard let p = checkRevision ? allPlugins.first(where: { $0.slug == slug }) : nil else {
            return // 版本核对失败 = 丢弃 (与 fetch 内联逻辑同判定)
        }
        _ = p
        apply(slug: slug, fetched: fetched, now: now)
    }
    /// 测试注入: 模拟账号被删 (registry 清空)
    func clearAllPluginsForTest() { allPlugins = []; states = [] }

    // MARK: P0-3 调度持久去重 (纯函数拆出可测)
    /// 键结构: ["yyyy-MM-dd|slug": ["HH:MM": "fired"|"skipped:<reason>"]]
    nonisolated static func scheduleDedupKey(slug: String, date: Date) -> String { scheduleKey(slug: slug, date: date) }

    /// 判定并登记: 返回 true = 应触发 (首次), false = 已触发过 (跳过)
    nonisolated static func markScheduleFired(fired: inout [String: [String: String]],
                                              slug: String, hhmm: String, date: Date = Date()) -> Bool {
        let key = scheduleDedupKey(slug: slug, date: date)
        if fired[key]?[hhmm] != nil { return false }
        fired[key, default: [:]][hhmm] = "fired"
        return true
    }

    private func pluginDir(slug: String) -> URL {
        // 用户目录优先, 其次 bundle
        let u = userDir.appendingPathComponent(slug, isDirectory: true)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        return bundleDir?.appendingPathComponent(slug, isDirectory: true) ?? u
    }

    private func apply(slug: String, fetched: UsageCache?, now: Double) {
        guard let i = states.firstIndex(where: { $0.slug == slug }) else { return }
        if let fetched {
            var snapshot = fetched
            if fetched.error != nil, var previous = states[i].cache,
               fetched.accountId == previous.accountId,
               cacheMatchesAuthSource(previous, slug: slug, manifest: states[i].manifest),
               fetched.accountId != nil || (states[i].manifest.authStyle != "local" && states[i].manifest.queryAuth != "header") {
                previous.error = fetched.error
                previous.stale = true
                previous.lastAttemptAt = fetched.lastAttemptAt ?? now
                snapshot = previous
            }
            writeCache(snapshot, plugin: states[i])
            states[i].cache = snapshot
            states[i].isStale = snapshot.error != nil || snapshot.stale == true
            // P1-3: 429 退避 — ratelimit → 暂停自动查询至 max(interval, 60s); 成功则清除暂停 (到期恢复的另一路径)
            var paused = Self.loadPaused(defaults: defaults)
            if fetched.error == "ratelimit" {
                paused[slug] = now + Self.rateLimitPauseMs(intervalSec: states[i].manifest.interval)
            } else {
                paused.removeValue(forKey: slug)
            }
            Self.savePaused(paused, defaults: defaults)
        } else {
            // local/header 的当前身份无法证实：进程失败不能沿用上一 CLI 账号的数据。
            let local = states[i].manifest.authStyle == "local" || states[i].manifest.queryAuth == "header"
            let previous = local ? nil : states[i].cache.flatMap {
                cacheMatchesAuthSource($0, slug: slug, manifest: states[i].manifest) ? $0 : nil
            }
            var old = previous ?? UsageCache(generatedAt: nil, fiveHour: nil, sevenDay: nil,
                                            monthly: nil, error: "fetch", stale: true)
            old.stale = true
            old.lastAttemptAt = now
            if old.error == nil { old.error = "fetch" }
            states[i].cache = old
            states[i].isStale = true
            writeCache(old, plugin: states[i])
        }
    }

    /// 凭证轮换后立即清除该账号的内存快照；磁盘删除由账号仓储负责。
    func invalidateSnapshot(_ slug: String) {
        guard let index = states.firstIndex(where: { $0.slug == slug }) else { return }
        states[index].cache = nil
        states[index].isStale = true
    }

    private func cacheMatchesAuthSource(_ cache: UsageCache, slug: String, manifest: ProviderManifest) -> Bool {
        guard let file = authURL(for: ProviderState(slug: slug, manifest: manifest, cache: nil, isStale: false)) else { return true }
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        guard config.authMode == "auth" else { return true }
        guard (try? ProviderAuthentication.resolveQuota(config)) != nil,
              let source = ProviderAuthentication.credentialFileURL(for: config),
              let modified = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return modified.timeIntervalSince1970 * 1000 <= (cache.generatedAt ?? 0)
    }

    func readCache(slug: String, manifest: ProviderManifest) -> UsageCache? {
        guard queryMigrationErrors[slug] == nil else { return nil }
        let p = DataEngine.cachePath(for: PluginProvider(slug: slug, manifest: manifest, dir: hudDir),
                                     hudDir: hudDir)
        guard let data = try? Data(contentsOf: p),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data),
              cacheMatchesAuthSource(cache, slug: slug, manifest: manifest) else { return nil }
        return cache
    }

    private func writeCache(_ cache: UsageCache, plugin state: ProviderState) {
        let p = DataEngine.cachePath(for: PluginProvider(slug: state.slug, manifest: state.manifest,
                                                         dir: hudDir),
                                     hudDir: hudDir)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: p, options: .atomic)
        }
    }
}
