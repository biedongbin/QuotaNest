import Foundation
import SwiftUI
import AppKit

// MARK: - 校验 (纯函数, 可测)

enum SettingsValidation {
    /// 严格 HH:MM (24h, 两位); 9:00 / 24:00 / 09:60 均非法
    static func isValidTime(_ t: String) -> Bool {
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// 有效 http(s) URL: scheme 限 http/https, host 非空且不含空白/百分号
    static func isValidURL(_ s: String) -> Bool {
        guard !s.isEmpty,
              s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
              let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty,
              !host.contains("%"), !host.contains(" ")
        else { return false }
        return true
    }

    /// P1-9 Key 意图: 空=保持原值 (keep), 清除是独立显式意图 (clear), 填了新值=替换
    enum KeyIntent: Equatable { case replace, clear }

    /// 配置校验 (P1-10 两级制): 仅结构错误拒绝保存 (名称空/非法);
    /// 执行性缺失 (key/url) 不再报错 — 可保存, 账号标「未配置」, 依赖配置的开关强制 off
    static func configErrors(name: String, key: String, url: String,
                             authStyle: String, builtin: Bool,
                             hasExistingKey: Bool = false) -> [String: String] {
        var e: [String: String] = [:]
        if name.trimmingCharacters(in: .whitespaces).isEmpty { e["name"] = "账号名称不能为空" }
        return e
    }

    /// P1-10 执行性缺失判定 (纯函数): true = 账号可保存但「未配置」(查询/调用不可用)
    static func isIncomplete(name: String, key: String, url: String,
                             authStyle: String, builtin: Bool,
                             hasExistingKey: Bool = false) -> Bool {
        guard authStyle == "apikey" else { return false }
        if key.trimmingCharacters(in: .whitespaces).isEmpty && !hasExistingKey { return true }
        if !builtin {
            let u = url.trimmingCharacters(in: .whitespaces)
            return u.isEmpty || !isValidURL(u)
        }
        return false
    }

    /// P1-9 落盘 Key 处理 (纯函数, 可测):
    /// clear → 清空; 空 + 已有盘上值 → 不动 (隐式 keep); 其余 → 写入草稿值
    static func resolveKey(draftKey: String, existingKey: String, intent: KeyIntent) -> String? {
        switch intent {
        case .clear: return ""
        case .replace:
            let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return (k.isEmpty && !existingKey.isEmpty) ? nil : k
        }
    }

    /// 定时校验: 待添加输入 + 已存在时间点 + 开启时至少一个
    static func triggerErrors(times: [String], timeInput: String,
                              triggerEnabled: Bool, canCall: Bool) -> [String: String] {
        guard canCall else { return [:] }
        var e: [String: String] = [:]
        let pending = timeInput.trimmingCharacters(in: .whitespaces)
        if !pending.isEmpty, !isValidTime(pending) {
            e["time"] = "时间必须是严格 HH:MM，例如 09:00；9:00 不合法"
        } else if !pending.isEmpty, times.contains(pending) {
            e["time"] = "此时间点已存在，请勿重复添加"
        }
        if times.contains(where: { !isValidTime($0) }) { e["times"] = "已有时间点格式错误，请移除后重填" }
        if Set(times).count != times.count { e["times"] = "时间点不可重复" }
        if triggerEnabled && times.isEmpty && pending.isEmpty {
            e["times"] = "开启模型定时调用时至少需要一个时间点"
        }
        return e
    }

    /// 新账号或既有账号从关闭转为开启时，都必须确认定时调用的消费。
    static func needsTriggerConfirm(base: Bool, current: Bool, isNew: Bool) -> Bool {
        current && (isNew || !base)
    }
}

// MARK: - P1-8 错误四态 (判定集中一处, UI 只读文案)

/// 能力四态: 判定函数集中于此, 各 tab 文案统一引用
/// 未配置 = 缺必需配置 (App 侧可补) / 未接入 = App 无该适配 /
/// 不支持 = 有证据服务不支持 / 待核实 = 证据不足
enum CapabilityStatus: Equatable {
    case configured            // 能力可用
    case notConfigured         // 未配置: 缺必需配置 (如调用端点未填、key 空)
    case notIntegrated         // 未接入: App 无该适配 (如通用模板的额度解析)
    case notSupported          // 不支持: 有证据服务端不提供该能力
    case unverified            // 待核实: 证据不足, 不能断言不支持

    var label: String {
        switch self {
        case .configured: return "已支持"
        case .notConfigured: return "未配置"
        case .notIntegrated: return "未接入"
        case .notSupported: return "不支持"
        case .unverified: return "待核实"
        }
    }

    /// 额度查询能力: 有 queryUrl/cacheFile = 可查 (configured);
    /// 通用自定义模板无解析适配 = notIntegrated (App 未接, 非服务不支持)
    static func quota(manifest: ProviderManifest) -> CapabilityStatus {
        if manifest.supportsQuota { return .configured }
        return .notIntegrated
    }

    /// 模型调用能力: manifest 有 refreshUrl (模板锁定) = configured;
    /// 模板实例无 refreshUrl = notIntegrated (App 尚未接入，不能推断服务不支持);
    /// 通用自定义 = notConfigured (服务地址未填时可补)
    static func call(manifest: ProviderManifest, configUrl: String) -> CapabilityStatus {
        if let r = manifest.refreshUrl, !r.isEmpty { return .configured }
        if manifest.template != nil { return .notIntegrated }
        return configUrl.trimmingCharacters(in: .whitespaces).isEmpty ? .notConfigured : .configured
    }
}

// MARK: - 草稿

/// 草稿值 (可比较 → dirty 判定)
struct DraftValues: Equatable {
    var name = ""
    var url = ""
    var key = ""
    var model = ""
    var prompt = ""
    var proto = "openai"
    var autoQuery = true
    var autoTrigger = false
    var times: [String] = []
    /// P1-9 显式清除 Key 意图 (确认后置位); 空输入 = 保持原值, 不置位
    var clearKeyIntent = false
    var queryURL = ""
    var queryKey = ""
    var queryToken = ""
    var queryCookie = ""
    var quotaMode = "none"
    var clearQueryKeyIntent = false
}

struct Draft: Equatable {
    /// nil = 新建
    var slug: String?
    /// 能力来源模板 slug (bundle); nil = 通用自定义
    var template: String?
    var isNew: Bool
    var values: DraftValues
    /// 进入草稿时的原值 (dirty 判据)
    var base: DraftValues
    var timeInput = ""

    var dirty: Bool { values != base || !timeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// P1-9: 编辑态盘上已有 Key (空输入保存 = 保持原值的判据)
    var hasExistingKey: Bool = false

    init(slug: String?, template: String?, isNew: Bool, values: DraftValues, base: DraftValues) {
        self.slug = slug
        self.template = template
        self.isNew = isNew
        self.values = values
        self.base = base
    }
}

// MARK: - 账号模型

struct AccountRow: Identifiable {
    let plugin: PluginProvider
    let state: ProviderState?
    let autoQuery: Bool
    /// v0.2 主开关「启用监控」: off = 不查询不调度不出现在菜单栏/HUD (复用 disabledSlugs 存储)
    let enabled: Bool
    /// P1-10 执行性配置完整 (key/url 齐) — false = 「未配置」徽章, 依赖配置的开关已强制 off
    let isConfigured: Bool

    var id: String { plugin.slug }
    var name: String { plugin.manifest.fullName }
    /// 有 queryUrl = 可查额度 (GPT/Cline 也有); 脚本型实例由 fetch.sh 直查, 由 cacheFile 声明
    var canQuery: Bool { plugin.manifest.supportsQuota }
    /// 有 refreshUrl = 可定时调用
    var canCall: Bool { plugin.manifest.refreshUrl != nil }
    /// 模板实例 = 内置 (地址由模板提供)
    var builtin: Bool { plugin.manifest.template != nil }
    var authStyle: String { plugin.manifest.authStyle }
    var authLabel: String {
        switch authStyle {
        case "apikey": return "API Key"
        case "oauth": return "授权登录 · OAuth"
        default: return "授权登录"
        }
    }

    /// 列表状态点: (色, 文案) — 停用优先于一切
    var status: (Color, String) {
        if !enabled { return (Palette.muted, "已停用") }
        if !isConfigured { return (Palette.warn, "未配置") }
        guard let c = state?.cache else { return (Palette.muted, "未查询") }
        if c.error != nil { return (Palette.danger, "异常") }
        return (Palette.ok, "正常")
    }
}

/// 模板目录项 (bundle 模板 + 两个通用兼容项)
struct TemplateChoice: Identifiable {
    let id: String          // bundle slug / "generic-openai" / "generic-anthropic"
    let label: String
    let detail: String
    let tag: String
    let authStyle: String
    let manifest: ProviderManifest?   // nil = 通用自定义
    let proto: String?
}

// MARK: - 跨重启记忆 (纯函数, 可测)

enum SettingsPersist {
    static let selectedKey = "tokenhud.settings.selected"
    static let tabKey = "tokenhud.settings.tab"

    /// 保存的 slug 仍存在则沿用, 否则回落第一个账号
    static func resumeSlug(saved: String?, available: [String]) -> String? {
        guard let saved, available.contains(saved) else { return available.first }
        return saved
    }

    static func resumeTab(saved: String?) -> SettingsModel.Tab {
        saved.flatMap(SettingsModel.Tab.init(rawValue:)) ?? .quota
    }
}

// MARK: - 地址行语义 (纯函数, 可测)

/// manifest.queryUrl 在模板里是**额度查询接口**, 不是服务根地址; 两者不能共用一行一标签。
struct AddressRow: Equatable {
    let label: String
    let value: String
    let note: String
}

enum AddressPresentation {
    static let builtinNote = "内置供应商，此项由模板提供，不可修改"

    /// 模板实例有 queryUrl → 额度查询地址 (模板提供); 通用自定义 → 服务地址 (用户填); 有调用端点再加一行
    static func rows(generic: Bool, queryUrl: String?, refreshUrl: String?,
                     configUrl: String) -> [AddressRow] {
        var out: [AddressRow] = []
        if generic {
            out.append(AddressRow(label: "服务地址",
                                  value: configUrl.isEmpty ? "未填写" : configUrl,
                                  note: "兼容 OpenAI / Anthropic 的服务根地址，用于额度查询与测试调用。"))
        } else if let q = queryUrl, !q.isEmpty {
            // 脚本型模板 manifest 无 queryUrl: 调用方读 auth 的 apiUrl 兜底
            out.append(AddressRow(label: "额度查询地址", value: q, note: builtinNote))
        }
        if let r = refreshUrl, !r.isEmpty {
            out.append(AddressRow(label: "调用地址", value: r,
                                  note: "测试调用实际请求的端点，只读。"))
        }
        return out
    }
}

// MARK: - 删除范围

/// 只允许清理本应用为该账号创建的固定路径, 不跟随 manifest 指向外部文件。
enum AccountFileOwnership {
    enum HUDFile: Equatable { case auth, cache }

    static func canRemoveHUDFile(_ candidate: URL, slug: String, kind: HUDFile,
                                 hudDir: URL) -> Bool {
        let suffix = kind == .auth ? "usage-auth.json" : "usage-cache.json"
        return matchesOwnedPath(candidate, slug: slug, name: ".\(slug)-\(suffix)",
                                root: hudDir, directory: false)
    }

    static func canRemovePluginDirectory(_ candidate: URL, slug: String,
                                         userDir: URL) -> Bool {
        matchesOwnedPath(candidate, slug: slug, name: slug, root: userDir, directory: true)
    }

    private static func matchesOwnedPath(_ candidate: URL, slug: String, name: String,
                                         root: URL, directory: Bool) -> Bool {
        guard ProviderRegistry.isValidSlug(slug) else { return false }
        let expected = root.standardizedFileURL.appendingPathComponent(name).standardizedFileURL
        guard candidate.standardizedFileURL == expected,
              candidate.resolvingSymlinksInPath().standardizedFileURL
                == root.resolvingSymlinksInPath().appendingPathComponent(name).standardizedFileURL,
              let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]),
              values.isSymbolicLink != true else { return false }
        return directory ? values.isDirectory == true : values.isRegularFile == true
    }
}

// MARK: - 模型

@MainActor
final class SettingsModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case quota, config, trigger
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quota: return "额度"
            case .config: return "配置"
            case .trigger: return "自动任务"
            }
        }
    }

    struct Toast: Equatable {
        let text: String
        let isError: Bool
    }

    let engine: DataEngine
    let hudDir: URL
    let userDir: URL
    let settingsURL: URL
    let bundleDir: URL?
    private let defaults: UserDefaults
    private let confirmDiscardChanges: (() -> Bool)?
    private let confirmResumePlan: (() -> Bool)?
    private let confirmTestCall: ((CallTestConfirmation) -> Bool)?
    private let executeTestCall: (ProviderConfig) async -> String?
    private var templatesReturn: (page: NavPage, selected: String?, tab: Tab)?

    @Published var search = ""
    /// v0.2 总览筛选: 全部 / API Key / 授权登录 / 已启用 / 已停用
    enum ScopeFilter: String, CaseIterable, Identifiable {
        case all, apikey, oauth, enabled, disabled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .apikey: return "API Key"
            case .oauth: return "授权登录"
            case .enabled: return "已启用"
            case .disabled: return "已停用"
            }
        }
    }

    @Published var scope: ScopeFilter = .all
    /// v0.2 左栏当前页: 总览 / 调用计划 / 全局设置 / 账号详情 (selected != nil 或模板/草稿)
    enum NavPage: Equatable { case overview, plan, settings, detail }
    @Published var navPage: NavPage = .overview
    @Published var selected: String? { didSet { persistSelection() } }
    @Published var tab: Tab = .quota { didSet { defaults.set(tab.rawValue, forKey: SettingsPersist.tabKey) } }
    @Published var showingTemplates = false
    @Published var draft: Draft?
    @Published var errors: [String: String] = [:]
    @Published var topError = ""
    @Published var running: Set<String> = []
    @Published private(set) var callRunning: Set<String> = []
    @Published private(set) var callTestResults: [String: CallTestResult] = [:]
    @Published private(set) var pendingTestConfirmation: CallTestConfirmation?
    private struct PendingTestCall {
        let config: ProviderConfig
        let key: String
        let source: String
    }
    private var pendingTestCall: PendingTestCall?
    private var newDraftTestKey = "new-draft-\(UUID().uuidString)"
    var callTestResultKey: String { draft?.isNew == true ? newDraftTestKey : (draft?.slug ?? selected ?? newDraftTestKey) }
    var isTestingCurrentConfig: Bool {
        callRunning.contains(callTestResultKey) || pendingTestCall?.key == callTestResultKey
    }
    func callTestResult(for slug: String?) -> CallTestResult? { callTestResults[slug ?? callTestResultKey] }

    @Published var toast: Toast?
    @Published var importOpen = false
    /// 每账号最近一次手动操作结果 (耗时/结果)
    @Published var lastRun: [String: (ok: Bool, ms: Int, at: Date)] = [:]
    /// 每账号最近一次成功查询时刻 (仅本次运行内记录; 失败刷新会把缓存 generatedAt 前移, 不能当成功时间)
    @Published var lastSuccess: [String: Date] = [:]

    private var toastTask: Task<Void, Never>?
    /// 导入 sheet 的状态源 (跨视图刷新保持; 关窗后丢弃)
    lazy var importer = ImportCenterModel(engine: engine, hudDir: hudDir, userDir: userDir)

    init(engine: DataEngine, hudDir: URL, userDir: URL, settingsURL: URL, bundleDir: URL?,
         defaults: UserDefaults = .standard, confirmDiscardChanges: (() -> Bool)? = nil,
         confirmResumePlan: (() -> Bool)? = nil,
         confirmTestCall: ((CallTestConfirmation) -> Bool)? = nil,
         executeTestCall: ((ProviderConfig) async -> String?)? = nil) {
        self.engine = engine
        self.hudDir = hudDir
        self.userDir = userDir
        self.settingsURL = settingsURL
        self.bundleDir = bundleDir
        self.defaults = defaults
        self.confirmDiscardChanges = confirmDiscardChanges
        self.confirmResumePlan = confirmResumePlan
        self.confirmTestCall = confirmTestCall
        self.executeTestCall = executeTestCall ?? { config in await RefreshTrigger.testRefresh(config: config) }
        // 恢上次的账号与 tab; 账号已不存在则回落第一个
        let slugs = engine.allPlugins.map(\.slug)
        self.selected = SettingsPersist.resumeSlug(
            saved: defaults.string(forKey: SettingsPersist.selectedKey), available: slugs)
        self.tab = SettingsPersist.resumeTab(saved: defaults.string(forKey: SettingsPersist.tabKey))
        // QA 自检: 打印跨重启恢复结果后退出 (真机验收用, 不参与业务)
        if ProcessInfo.processInfo.environment["TOKENHUD_DEBUG_SETTINGS"] == "1" {
            print("SETTINGS RESUME selected=\(self.selected ?? "nil") tab=\(self.tab.rawValue)")
            exit(0)
        }
    }

    /// 选中账号落盘 (nil 不覆盖, 留给回落逻辑)
    private func persistSelection() {
        guard let selected else { return }
        defaults.set(selected, forKey: SettingsPersist.selectedKey)
    }

    // MARK: 派生

    /// 全部账号独立于总览搜索, 供计划页和全局设置使用。
    var allAccounts: [AccountRow] {
        engine.allPlugins.map { p in
            AccountRow(plugin: p,
                       state: engine.states.first { $0.slug == p.slug } ?? cachedState(for: p),
                       autoQuery: !engine.disabledSlugs.contains(p.slug),
                       enabled: !engine.disabledSlugs.contains(p.slug),
                       isConfigured: Self.configured(p, readConfig: readConfig))
        }
    }

    var accounts: [AccountRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allAccounts }
        return allAccounts.filter {
            $0.name.lowercased().contains(q) || $0.plugin.manifest.label.lowercased().contains(q)
        }
    }

    /// 总览按供应商分组 (manifest.label 分组键, fullName 组头; v0.2 受 scope 筛选)
    var overviewGroups: [(label: String, fullName: String, accent: String?, icon: String?, rows: [AccountRow])] {
        let all = accounts
        let scoped: [AccountRow]
        switch scope {
        case .all: scoped = all
        case .apikey: scoped = all.filter { $0.authStyle == "apikey" }
        case .oauth: scoped = all.filter { $0.authStyle != "apikey" }
        case .enabled: scoped = all.filter { $0.enabled }
        case .disabled: scoped = all.filter { !$0.enabled }
        }
        var order: [String] = []
        var byLabel: [String: [AccountRow]] = [:]
        var info: [String: (String, String?, String?)] = [:]
        for r in scoped {
            let template = r.plugin.manifest.template.flatMap { engine.template(bySlug: $0)?.manifest }
            let provider = template ?? r.plugin.manifest
            let key = provider.label
            if byLabel[key] == nil {
                byLabel[key] = []
                order.append(key)
                info[key] = (providerName(for: r), provider.accent, provider.icon)
            }
            byLabel[key]?.append(r)
        }
        return order.map { ($0, info[$0]!.0, info[$0]!.1, info[$0]!.2, byLabel[$0]!) }
    }

    /// 左栏分组 (API Key / 授权登录)
    var grouped: [(String, [AccountRow])] {
        let all = accounts
        return [("API Key", all.filter { $0.authStyle == "apikey" }),
                ("授权登录", all.filter { $0.authStyle != "apikey" })]
            .filter { !$0.1.isEmpty }
    }

    func row(_ slug: String?) -> AccountRow? {
        guard let slug, let p = engine.allPlugins.first(where: { $0.slug == slug }) else { return nil }
        return AccountRow(plugin: p,
                          state: engine.states.first { $0.slug == slug } ?? cachedState(for: p),
                          autoQuery: !engine.disabledSlugs.contains(slug),
                          enabled: !engine.disabledSlugs.contains(slug),
                          isConfigured: Self.configured(p, readConfig: readConfig))
    }

    /// P1-10 执行性配置完整判定 (静态, 供 AccountRow 构建)
    nonisolated private static func configured(_ p: PluginProvider,
                                               readConfig: (PluginProvider) -> ProviderConfig) -> Bool {
        let cfg = readConfig(p)
        let callReady = SettingsValidation.isValidURL(cfg.refreshUrl)
            && !cfg.refreshKey.isEmpty && !cfg.testModel.isEmpty
        let queryReady = Self.queryReady(p.manifest, config: cfg)
        return callReady || queryReady
    }

    nonisolated private static func queryReady(_ manifest: ProviderManifest, config: ProviderConfig) -> Bool {
        guard manifest.supportsQuota else { return false }
        if config.quotaMode == "endpoint", !SettingsValidation.isValidURL(config.queryUrl) { return false }
        switch manifest.queryAuth {
        case "jwt": return !config.queryToken.isEmpty
        case "cookie": return !config.queryCookie.isEmpty
        case "header": return true
        default: return !config.queryKey.isEmpty || !config.queryCookie.isEmpty
        }
    }

    func callConfigured(_ row: AccountRow) -> Bool {
        let cfg = readConfig(row.plugin)
        return SettingsValidation.isValidURL(cfg.refreshUrl) && !cfg.refreshKey.isEmpty && !cfg.testModel.isEmpty
    }

    func quotaConfigured(_ row: AccountRow) -> Bool {
        Self.queryReady(row.plugin.manifest, config: readConfig(row.plugin))
    }

    /// 关闭自动查询后账号不在 states 里, 但缓存文件仍在 → 直接读盘 (手动查询结果照常显示)
    private func cachedState(for p: PluginProvider) -> ProviderState? {
        let path = DataEngine.cachePath(for: p, hudDir: hudDir)
        guard let data = try? Data(contentsOf: path),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data) else { return nil }
        return ProviderState(slug: p.slug, manifest: p.manifest, cache: cache,
                             isStale: !HUDFmt.isFresh(cache, interval: p.manifest.interval,
                                                      now: Date().timeIntervalSince1970 * 1000))
    }

    var current: AccountRow? { row(selected) }

    var choices: [TemplateChoice] {
        let builtin = engine.templates.map { t -> TemplateChoice in
            let queries = t.manifest.queryUrl != nil || t.manifest.cacheFile != nil
            return TemplateChoice(id: t.slug, label: t.manifest.fullName,
                                  detail: queries ? "内置 · 地址由模板提供" : "内置 · 只提供额度查询",
                                  tag: t.manifest.authStyle == "apikey" ? "API Key" : "本机 CLI",
                                  authStyle: t.manifest.authStyle, manifest: t.manifest,
                                  proto: t.manifest.refreshProtocol)
        }
        return builtin + [
            TemplateChoice(id: "generic-openai", label: "通用 OpenAI 兼容", detail: "自定义 · 可改地址",
                           tag: "API Key", authStyle: "apikey", manifest: nil, proto: "openai"),
            TemplateChoice(id: "generic-anthropic", label: "通用 Anthropic 兼容", detail: "自定义 · 可改地址",
                           tag: "API Key", authStyle: "apikey", manifest: nil, proto: "anthropic"),
        ]
    }

    /// 当前草稿的能力来源 manifest
    func draftManifest() -> ProviderManifest? {
        guard let d = draft else { return nil }
        if let slug = d.slug, let provider = engine.allPlugins.first(where: { $0.slug == slug }) {
            return provider.manifest
        }
        if let t = d.template { return engine.template(bySlug: t)?.manifest }
        return nil
    }

    func draftCanCall() -> Bool {
        if draftBuiltin() { return draftManifest()?.refreshUrl?.isEmpty == false }
        return draft != nil
    }

    func providerName(for row: AccountRow) -> String {
        if let template = row.plugin.manifest.template,
           let base = engine.template(bySlug: template)?.manifest {
            return base.fullName
        }
        return row.plugin.manifest.label
    }
    func draftBuiltin() -> Bool { draft?.template != nil }
    func draftAuthStyle() -> String { draftManifest()?.authStyle ?? "apikey" }

    /// 模板 auth-template.json 的 apiUrl (脚本型模板的查询地址事实源)
    private func templateAuthURL(_ slug: String) -> String {
        guard let t = engine.template(bySlug: slug),
              let data = try? Data(contentsOf: t.dir.appendingPathComponent("auth-template.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return obj["apiUrl"] as? String ?? ""
    }

    // MARK: 草稿动作

    @discardableResult
    func selectAccount(_ slug: String, tab targetTab: Tab = .quota) -> Bool {
        guard engine.allPlugins.contains(where: { $0.slug == slug }), leaveGuard() else { return false }
        clearDraft()
        templatesReturn = nil
        selected = slug
        showingTemplates = false
        tab = targetTab
        navPage = .detail
        return true
    }

    /// 导航切页先处理草稿; 拒绝离开时不改变页面、账号或 tab。
    func navigate(to page: NavPage) {
        guard page != navPage else { return }
        guard leaveGuard() else { return }
        if page != .detail {
            showingTemplates = false
            clearDraft()
            templatesReturn = nil
        }
        navPage = page
    }

    func openTemplates() {
        guard leaveGuard() else { return }
        if !showingTemplates { templatesReturn = (navPage, selected, tab) }
        clearDraft()
        showingTemplates = true
        navPage = .detail
    }

    /// 取消添加后返回原页面, 不选择其它账号。
    func closeTemplates() {
        showingTemplates = false
        if let destination = templatesReturn {
            selected = destination.selected
            tab = destination.tab
            navPage = destination.page
        } else {
            navPage = .overview
        }
        templatesReturn = nil
    }

    /// P2-1 导入入口同走草稿 guard (与 selectAccount/openTemplates 同一保护规则)
    func openImport() {
        guard leaveGuard() else { return }
        importOpen = true
    }

    func startEdit() {
        guard let row = current else { return }
        let cfg = readConfig(row.plugin)
        var v = DraftValues(name: row.name, url: cfg.apiBaseURL, key: cfg.refreshKey,
                            model: cfg.testModel, prompt: cfg.testPrompt, proto: cfg.refreshProtocol,
                            autoQuery: row.enabled,
                            autoTrigger: !engine.triggerDisabledSlugs.contains(row.id)
                                && !cfg.scheduleTimes.isEmpty && row.canCall, times: cfg.scheduleTimes)
        v.queryURL = cfg.queryUrl
        v.queryKey = cfg.queryKey
        v.queryToken = cfg.queryToken
        v.queryCookie = cfg.queryCookie
        v.quotaMode = cfg.quotaMode
        draft = Draft(slug: row.id, template: row.plugin.manifest.template, isNew: false, values: v, base: v)
        draft?.hasExistingKey = !cfg.refreshKey.isEmpty
        errors = [:]; topError = ""
    }

    func duplicateAccount(_ slug: String) {
        guard leaveGuard(), row(slug) != nil else { return }
        selected = slug
        startEdit()
        guard var copy = draft else { return }
        copy.slug = nil
        copy.isNew = true
        copy.hasExistingKey = false
        copy.values.name += " 副本"
        copy.values.key = ""
        copy.values.queryKey = ""
        copy.values.queryToken = ""
        copy.values.queryCookie = ""
        copy.values.autoTrigger = false
        copy.values.clearKeyIntent = false
        copy.values.clearQueryKeyIntent = false
        copy.base = DraftValues()
        draft = copy
        newDraftTestKey = "new-draft-\(UUID().uuidString)"
        showingTemplates = false
        navPage = .detail
        tab = .config
        flash("已复制配置，请填写新账号凭证；定时调用保持关闭", error: false)
    }

    func discardDraft() {
        clearDraft()
        showingTemplates = false
        errors = [:]
        topError = ""
        tab = .config
    }

    func pickTemplate(_ choice: TemplateChoice) {
        guard leaveGuard() else { return }
        let m = choice.manifest
        newDraftTestKey = "new-draft-\(UUID().uuidString)"
        var v = DraftValues(name: (m?.fullName ?? "自定义") + " 新账号",
                            url: APIEndpoint.baseURL(from: m?.refreshUrl ?? ""), key: "",
                            model: m?.testModel ?? "", prompt: m?.testPrompt ?? ProviderConfig.defaultPrompt,
                            proto: m?.refreshProtocol ?? choice.proto ?? "openai", autoQuery: true,
                            autoTrigger: false, times: [])
        v.queryURL = m?.queryUrl ?? templateAuthURL(choice.id)
        v.quotaMode = m == nil ? "none" : "script"
        draft = Draft(slug: nil, template: choice.manifest.map { _ in choice.id }, isNew: true,
                      values: v, base: DraftValues())
        errors = [:]; topError = ""
        showingTemplates = false
        tab = .config
    }

    /// 取消草稿 (未保存改动先确认)
    func cancelEdit() {
        guard leaveGuard() else { return }
        let wasNew = draft?.isNew ?? false
        clearDraft()
        if wasNew {
            showingTemplates = true
        } else {
            tab = .config
        }
        flash("草稿已取消", error: false)
    }

    func addTime() {
        guard var d = draft else { return }
        let t = d.timeInput.trimmingCharacters(in: .whitespaces)
        guard SettingsValidation.isValidTime(t) else {
            errors["time"] = "请使用严格的 HH:MM 格式，例如 09:00；9:00 不合法"
            topError = errors["time"] ?? ""
            return
        }
        guard !d.values.times.contains(t) else {
            errors["time"] = "此时间点已存在，请勿重复添加"
            topError = errors["time"] ?? ""
            return
        }
        d.values.times.append(t)
        d.values.times.sort()
        d.timeInput = ""
        errors["time"] = nil; errors["times"] = nil
        topError = ""
        draft = d
        flash("已加入草稿：\(t)", error: false)
    }

    func removeTime(at index: Int) {
        guard var d = draft, d.values.times.indices.contains(index) else { return }
        let removed = d.values.times.remove(at: index)
        draft = d
        flash("已从草稿移除 \(removed)", error: false)
    }

    func save() {
        guard let d = draft else { return }
        guard !isTestingCurrentConfig else {
            topError = "测试调用进行中，请等待结果后再保存；当前输入已保留。"
            flash(topError, error: true)
            return
        }
        let testResultKey = callTestResultKey
        var errs = SettingsValidation.configErrors(
            name: d.values.name, key: d.values.key, url: d.values.url,
            authStyle: draftAuthStyle(), builtin: draftBuiltin(),
            hasExistingKey: d.isNew ? false : d.hasExistingKey)
        if !d.values.url.isEmpty && !SettingsValidation.isValidURL(d.values.url) {
            errs["url"] = "API Base URL 必须是有效的 http(s) 地址"
        }
        if d.values.quotaMode == "endpoint" && !d.values.queryURL.isEmpty
            && !SettingsValidation.isValidURL(d.values.queryURL) {
            errs["queryURL"] = "额度查询 URL 必须是有效的 http(s) 地址"
        }
        let triggerErrs = SettingsValidation.triggerErrors(
            times: d.values.times, timeInput: d.timeInput,
            triggerEnabled: d.values.autoTrigger, canCall: draftCanCall())
        errs.merge(triggerErrs) { a, _ in a }
        errors = errs
        topError = errs.values.sorted().joined(separator: "；")
        guard errs.isEmpty else {
            if !d.isNew { tab = errs["time"] != nil || errs["times"] != nil ? .trigger : .config }
            return
        }
        // 待添加时间点在保存时并入
        var values = d.values
        let pending = d.timeInput.trimmingCharacters(in: .whitespaces)
        if draftCanCall(), !pending.isEmpty {
            values.times.append(pending)
            values.times.sort()
        }
        // P1-6: autoTrigger off→on 保存前需消费确认; 拒绝则保持 off (该开关不保存, 其余照常)
        if SettingsValidation.needsTriggerConfirm(base: d.base.autoTrigger, current: values.autoTrigger,
                                                  isNew: d.isNew) {
            let confirmed: Bool
            if let confirmResumePlan { confirmed = confirmResumePlan() }
            else {
                let alert = NSAlert()
                alert.messageText = "开启模型定时调用？"
                let name = values.name.trimmingCharacters(in: .whitespaces)
                alert.informativeText = "开启后 \(name) 将在设定时间点自动发送一次模型调用，每次都会消耗该账号额度。确定开启？"
                alert.addButton(withTitle: "开启")
                alert.addButton(withTitle: "取消保存")
                alert.alertStyle = .warning
                confirmed = alert.runModal() == .alertFirstButtonReturn
            }
            guard confirmed else {
                topError = "已取消保存，模型定时调用未启用；当前输入已保留。"
                flash(topError, error: true)
                return
            }
        }
        do {
            // 额度查询可缺失；仅调用配置不完整时暂停消费计划。
            let incomplete = !draftCallReady(values)
            if incomplete { values.autoTrigger = false }
            let slug = d.isNew ? try create(values: values, draft: d)
                               : try update(values: values, draft: d)
            engine.reloadRegistry()
            if d.isNew, let result = callTestResults.removeValue(forKey: testResultKey) {
                callTestResults[slug] = result
            }
            clearDraft()
            showingTemplates = false
            templatesReturn = nil
            selected = slug
            if d.isNew { tab = .config }
            navPage = .detail
            flash(incomplete
                  ? "已保存；API 调用配置待补全，定时调用保持关闭"
                  : "已保存：\(values.name.trimmingCharacters(in: .whitespaces))", error: false)
            // P1-1: 保存不发请求 (FR-05.2) — 不再触发 forceRefresh; 新快照等 interval 到期由 10s timer 按 isAttemptFresh 判定
        } catch {
            topError = "保存失败：\(error.localizedDescription)"
            flash("保存失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: 读/写

    func readConfig(_ p: PluginProvider) -> ProviderConfig {
        guard let af = authURL(p) else { return ProviderConfig() }
        return ProviderConfigStore.read(authFile: af, manifest: p.manifest)
    }

    func authURL(_ p: PluginProvider) -> URL? {
        if let af = p.manifest.authFile { return PluginGenerator.expandPath(af) }
        return hudDir.appendingPathComponent(".\(p.slug)-usage-auth.json")
    }

    private func draftConfig(_ values: DraftValues, existing: ProviderConfig? = nil) -> ProviderConfig {
        var cfg = existing ?? ProviderConfig()
        let existingCallKey = cfg.refreshKey
        if let key = SettingsValidation.resolveKey(draftKey: values.key, existingKey: existingCallKey,
            intent: values.clearKeyIntent ? .clear : .replace) { cfg.refreshKey = key }
        if values.clearQueryKeyIntent {
            cfg.queryKey = ""; cfg.queryToken = ""; cfg.queryCookie = ""
        } else {
            if !values.queryKey.isEmpty || existing == nil { cfg.queryKey = values.queryKey }
            if !values.queryToken.isEmpty || existing == nil { cfg.queryToken = values.queryToken }
            if !values.queryCookie.isEmpty || existing == nil { cfg.queryCookie = values.queryCookie }
        }
        cfg.apiBaseURL = values.url.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.refreshProtocol = values.proto
        cfg.refreshUrl = APIEndpoint.requestURL(baseURL: cfg.apiBaseURL, protocolName: cfg.refreshProtocol)
        cfg.refreshHeader = values.proto == "anthropic"
            ? "x-api-key: <key>\nanthropic-version: 2023-06-01" : "Authorization: Bearer <key>"
        if existing?.refreshProtocol == values.proto, let header = draftManifest()?.refreshHeader, !header.isEmpty {
            cfg.refreshHeader = header
        }
        cfg.queryUrl = values.queryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.quotaMode = values.quotaMode
        cfg.testModel = values.model.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.testPrompt = values.prompt
        cfg.scheduleTimes = values.times
        if let manifest = draftManifest(), draftBuiltin() {
            cfg.refreshUrl = manifest.refreshUrl ?? ""
            cfg.apiBaseURL = APIEndpoint.baseURL(from: cfg.refreshUrl)
            cfg.refreshProtocol = manifest.refreshProtocol ?? cfg.refreshProtocol
            cfg.refreshHeader = manifest.refreshHeader ?? cfg.refreshHeader
        }
        return cfg
    }

    private func draftCallReady(_ values: DraftValues) -> Bool {
        let existing = draft?.slug.flatMap { slug in engine.allPlugins.first { $0.slug == slug }.map(readConfig) }
        let cfg = draftConfig(values, existing: existing)
        return SettingsValidation.isValidURL(cfg.refreshUrl) && !cfg.refreshKey.isEmpty && !cfg.testModel.isEmpty
    }

    private func create(values: DraftValues, draft d: Draft) throws -> String {
        let name = values.name.trimmingCharacters(in: .whitespaces)
        let base = PluginGenerator.slugify(name)
        var slug = base
        var n = 2
        while engine.allPlugins.contains(where: { $0.slug == slug }) || FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        var cfg = draftConfig(values)
        let manifest: ProviderManifest
        if let type = d.template, let template = engine.template(bySlug: type) {
            manifest = try PluginGenerator.instantiate(template: template, slug: slug, name: name,
                                                       into: userDir, hudDir: hudDir)
            let defaults = ProviderConfigStore.read(authFile: PluginGenerator.expandPath(manifest.authFile ?? ""),
                                                    manifest: manifest)
            if cfg.queryUrl.isEmpty { cfg.queryUrl = defaults.queryUrl }
            cfg.quotaMode = "script"
        } else {
            manifest = PluginGenerator.customManifest(name: name, config: cfg,
                authFile: PluginGenerator.authPath(slug: slug, hudDir: hudDir))
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest,
                script: PluginGenerator.oneAPIFetchScript(slug: slug), into: userDir)
        }
        let af = PluginGenerator.expandPath(PluginGenerator.authPath(slug: slug, hudDir: hudDir))
        try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
        applyToggles(slug: slug, values: values, manifest: manifest)
        return slug
    }

    private func update(values: DraftValues, draft d: Draft) throws -> String {
        guard let slug = d.slug, let p = engine.allPlugins.first(where: { $0.slug == slug }),
              let af = authURL(p) else {
            throw NSError(domain: "TokenHUD", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "账号已不存在，请重新选择"])
        }
        if p.manifest.authStyle != "apikey",
           !AccountFileOwnership.canRemoveHUDFile(af, slug: slug, kind: .auth, hudDir: hudDir) {
            throw NSError(domain: "TokenHUD", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "凭证来自外部只读文件，请新建独立账号"])
        }
        let previous = readConfig(p)
        let cfg = draftConfig(values, existing: previous)
        let changedQuota = cfg.queryKey != previous.queryKey || cfg.queryToken != previous.queryToken
            || cfg.queryCookie != previous.queryCookie || cfg.queryUrl != previous.queryUrl
            || cfg.quotaMode != previous.quotaMode
        var manifest = p.manifest
        if manifest.template == nil {
            let generated = PluginGenerator.customManifest(name: values.name, config: cfg,
                authFile: PluginGenerator.authPath(slug: slug, hudDir: hudDir))
            manifest = generated
            manifest.origin = p.manifest.origin
        }
        manifest.displayName = values.name.trimmingCharacters(in: .whitespaces)
        let script = manifest.template == nil ? PluginGenerator.oneAPIFetchScript(slug: slug)
            : try String(contentsOf: p.dir.appendingPathComponent("fetch.sh"), encoding: .utf8)
        try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: script, into: userDir)
        try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
        if changedQuota {
            let cache = DataEngine.cachePath(for: p, hudDir: hudDir)
            if AccountFileOwnership.canRemoveHUDFile(cache, slug: slug, kind: .cache, hudDir: hudDir),
               FileManager.default.fileExists(atPath: cache.path) {
                try FileManager.default.removeItem(at: cache)
            }
            engine.invalidateSnapshot(slug)
        }
        applyToggles(slug: slug, values: values, manifest: manifest)
        return slug
    }

    private func applyToggles(slug: String, values: DraftValues, manifest: ProviderManifest) {
        engine.setTracking(slug, enabled: values.autoQuery)
        let callable = manifest.refreshUrl != nil
        engine.setTriggerEnabled(slug, enabled: callable && values.autoTrigger)
    }

    // MARK: 动作

    func query(_ slug: String) {
        guard let row = row(slug), row.canQuery else {
            flash("该账号没有额度查询地址，无法查询额度", error: true)
            return
        }
        guard !running.contains(slug) else { return }
        running.insert(slug)
        let started = Date()
        Task {
            let outcome = await engine.forceRefresh(slug: slug)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            running.remove(slug)
            lastRun[slug] = (outcome.ok, ms, Date())
            if outcome.ok { lastSuccess[slug] = Date() }
            flash(outcome.ok ? "额度已更新（\(ms) ms）" : "查询失败：\(outcome.reason)", error: !outcome.ok)
            if outcome.ok { engine.reloadRegistry() }
        }
    }

    func testCall(_ slug: String) {
        guard let row = row(slug), row.canCall else {
            flash("该账号尚未接入模型调用", error: true)
            return
        }
        var config = readConfig(row.plugin)
        if config.testModel.isEmpty { config.testModel = row.plugin.manifest.refreshModel }
        if config.testPrompt.isEmpty, let prompt = row.plugin.manifest.testPrompt { config.testPrompt = prompt }
        performTestCall(config: config, key: slug, source: "已保存配置", providerName: row.name)
    }

    /// 供测试与模型目录共用点击时的配置快照，不保存、不发请求。
    func callConfigForDraft(_ values: DraftValues) -> ProviderConfig {
        let existing = draft?.slug.flatMap { slug in engine.allPlugins.first { $0.slug == slug }.map(readConfig) }
        return draftConfig(values, existing: existing)
    }

    /// 使用点击时的当前输入，不保存凭证、配置或计划。
    func testCallDraft(values: DraftValues) {
        guard draft != nil else { flash("请先打开账号配置", error: true); return }
        let config = callConfigForDraft(values)
        performTestCall(config: config, key: callTestResultKey, source: "当前输入",
                        providerName: values.name.isEmpty ? "新账号" : values.name)
    }

    private func performTestCall(config: ProviderConfig, key: String, source: String, providerName: String) {
        let target = CallTestResult.targetDescription(config.refreshUrl)
        func result(_ phase: CallTestResult.Phase, _ message: String) -> CallTestResult {
            CallTestResult(phase: phase, model: config.testModel, target: target,
                           sourceLabel: source, message: message, date: Date())
        }
        guard !callRunning.contains(key) else { flash("该账号已有测试进行中", error: true); return }
        let invalid: String?
        if !SettingsValidation.isValidURL(config.refreshUrl) { invalid = "请先填写有效的调用地址" }
        else if config.refreshKey.isEmpty { invalid = "请先填写调用凭证；已清除的凭证不会用于测试" }
        else if config.testModel.isEmpty { invalid = "请先填写测试模型" }
        else { invalid = nil }
        if let invalid {
            callTestResults[key] = result(.failure, invalid)
            flash(invalid, error: true)
            return
        }
        guard pendingTestCall == nil else { flash("请先发送或取消当前待确认的测试", error: false); return }
        let confirmation = CallTestConfirmation(sourceLabel: source, model: config.testModel,
                                                target: target, providerName: providerName)
        if let confirmTestCall {
            guard confirmTestCall(confirmation) else { flash("已取消测试，未发送请求", error: false); return }
            executeConfirmedTestCall(config: config, key: key, source: source)
        } else {
            pendingTestCall = PendingTestCall(config: config, key: key, source: source)
            pendingTestConfirmation = confirmation
        }
    }

    func cancelPendingTestCall() {
        guard pendingTestCall != nil else { return }
        pendingTestCall = nil
        pendingTestConfirmation = nil
        flash("已取消测试，未发送请求", error: false)
    }

    func confirmPendingTestCall() {
        guard let pending = pendingTestCall else { return }
        pendingTestCall = nil
        pendingTestConfirmation = nil
        executeConfirmedTestCall(config: pending.config, key: pending.key, source: pending.source)
    }

    private func executeConfirmedTestCall(config: ProviderConfig, key: String, source: String) {
        guard !callRunning.contains(key) else { flash("该账号已有测试进行中", error: true); return }
        let target = CallTestResult.targetDescription(config.refreshUrl)
        func result(_ phase: CallTestResult.Phase, _ message: String) -> CallTestResult {
            CallTestResult(phase: phase, model: config.testModel, target: target,
                           sourceLabel: source, message: message, date: Date())
        }
        callRunning.insert(key)
        callTestResults[key] = result(.running, "正在发送一次测试调用…")
        let execute = executeTestCall
        Task {
            guard await engine.callSlots.acquire(key) else {
                callRunning.remove(key)
                callTestResults[key] = result(.failure, "调用繁忙：已有调用进行中，本次未发送")
                flash("调用繁忙，本次未发送", error: true)
                return
            }
            let started = Date()
            let response = await execute(config)
            await engine.callSlots.release(key)
            callRunning.remove(key)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let phase: CallTestResult.Phase = response?.hasPrefix("✓") == true ? .success
                : (response?.contains("结果不确定") == true ? .uncertain : .failure)
            let message: String
            if phase == .success { message = "调用成功（\(milliseconds) ms）" }
            else {
                message = ProviderRunner.redact(response ?? "调用未返回可验证的结果")
                    .replacingOccurrences(of: config.refreshKey, with: "[已隐藏]")
                    .replacingOccurrences(of: config.refreshUrl, with: target)
            }
            callTestResults[key] = result(phase, message)
            let summary = phase == .success ? message
                : (phase == .uncertain ? "测试结果不确定，可能已消费；请查看下方完整详情" : "测试调用未成功，请查看下方完整详情")
            flash(summary, error: phase != .success)
        }
    }

    func delete(_ slug: String) {
        guard let p = engine.allPlugins.first(where: { $0.slug == slug }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(p.manifest.fullName)?"
        alert.informativeText = "将移除本应用的账号记录与自有凭证、缓存。外部凭证或数据来源文件会保留。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard AccountFileOwnership.canRemovePluginDirectory(p.dir, slug: slug, userDir: userDir) else {
            flash("无法删除：账号目录不属于本应用，已保留外部文件。", error: true)
            return
        }
        do {
            try PluginGenerator.removePlugin(slug: slug, in: userDir)
        } catch {
            flash("删除账号失败：\(error.localizedDescription)", error: true)
            return
        }
        if p.manifest.template != nil { engine.markTemplateDeleted(slug) }
        var cleanupFailures: [String] = []
        var preservedSources = false
        let fm = FileManager.default
        if let af = authURL(p) {
            if AccountFileOwnership.canRemoveHUDFile(af, slug: slug, kind: .auth, hudDir: hudDir) {
                do { try fm.removeItem(at: af) }
                catch { cleanupFailures.append("凭证文件未移除") }
            } else if fm.fileExists(atPath: af.path) {
                preservedSources = true
            }
        }
        let cache = DataEngine.cachePath(for: p, hudDir: hudDir)
        if AccountFileOwnership.canRemoveHUDFile(cache, slug: slug, kind: .cache, hudDir: hudDir) {
            do { try fm.removeItem(at: cache) }
            catch { cleanupFailures.append("额度缓存未移除") }
        } else if fm.fileExists(atPath: cache.path) {
            preservedSources = true
        }
        engine.forgetAccountSettings(slug)
        clearDraft()
        selected = nil
        navPage = .overview
        engine.reloadRegistry()
        let hasSameName = engine.allPlugins.contains { $0.manifest.name == p.manifest.name }
        let removed = hasSameName ? Set([p.slug]) : Set([p.slug, p.manifest.name])
        if case .failure(let error) = engine.writeEnvsForHudSync(removingManagedNames: removed) {
            cleanupFailures.append("HUD 未更新：\(error.localizedDescription)")
        }
        if cleanupFailures.isEmpty {
            flash("已删除 \(p.manifest.fullName)" + (preservedSources ? "，外部来源文件已保留" : ""), error: false)
        } else {
            flash("已移除 \(p.manifest.fullName)，但\(cleanupFailures.joined(separator: "；"))", error: true)
        }
    }

    func syncHUD() {
        engine.installScripts()
        switch engine.writeEnvsForHudSync() {
        case .success:
            flash("已写入 Claude Code HUD（下次渲染生效）", error: false)
        case .failure(let error):
            flash("写入 HUD 失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: v0.2 总览三开关 (即时生效, 不走草稿)

    /// 停用暂停后台工作但保留计划; 重新启用已配置的调用计划前确认消费。
    func toggleMonitoring(_ slug: String, enabled: Bool) {
        guard let account = row(slug) else {
            flash("账号不存在，无法修改启用状态", error: true)
            return
        }
        if enabled && !account.enabled && account.canCall
            && !engine.triggerDisabledSlugs.contains(slug) {
            let times = readConfig(account.plugin).scheduleTimes
            if !times.isEmpty {
                let confirmed: Bool
                if let confirmResumePlan {
                    confirmed = confirmResumePlan()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "启用账号并恢复定时调用？"
                    alert.informativeText = "\(account.name) 已设置 \(times.joined(separator: "、")) 定时调用。启用后计划将恢复，每次调用会消耗额度。"
                    alert.addButton(withTitle: "启用并恢复")
                    alert.addButton(withTitle: "取消")
                    alert.alertStyle = .warning
                    confirmed = alert.runModal() == .alertFirstButtonReturn
                }
                guard confirmed else { return }
            }
        }
        engine.setTracking(slug, enabled: enabled)
        if var currentDraft = draft, currentDraft.slug == slug {
            currentDraft.values.autoQuery = enabled
            currentDraft.base.autoQuery = enabled
            draft = currentDraft
        }
        let sync = engine.writeEnvsForHudSync()
        let name = account.name
        switch sync {
        case .success:
            flash(enabled ? "已启用 \(name)" : "已停用 \(name)，后台查询和定时调用已暂停",
                  error: false)
        case .failure(let error):
            flash("\(name) 已\(enabled ? "启用" : "停用")，但 HUD 未更新：\(error.localizedDescription)",
                  error: true)
        }
    }

    /// 「悬浮窗显示」: 只影响悬浮窗/菜单栏展示
    func toggleFloating(_ slug: String, shown: Bool) {
        engine.setFloatingHidden(slug, hidden: !shown)
        flash(shown ? "已在悬浮窗与菜单栏显示该账号" : "已从悬浮窗与菜单栏隐藏该账号（查询不受影响）",
              error: false)
    }

    /// 「同步 HUD」: 关闭即时从 envs.json / ACCOUNT_ENVS 摘除
    func toggleHudSync(_ slug: String, synced: Bool) {
        switch engine.setHudHidden(slug, hidden: !synced) {
        case .success:
            flash(synced ? "已同步该账号到 Claude Code HUD" : "已从 Claude Code HUD 摘除该账号",
                  error: false)
        case .failure(let error):
            flash("HUD 同步失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: v0.2 调用计划页数据 (全部账号的定时计划 + 最近执行结果)

    struct PlanRow: Identifiable {
        let slug: String
        var id: String { slug }
        let name: String
        let providerName: String
        let accent: String?
        let icon: String?
        let canCall: Bool
        let enabled: Bool                 // 账号与已配置计划均启用
        let pausedByAccount: Bool
        let times: [String]
        /// 今日最新登记的状态; nil 表示今日无记录, 不推断是否已执行。
        let lastOutcome: String?
    }

    /// 调度记录 → 每账号 HH:MM → 结果 ("fired" / "skipped:<reason>"), 只看今天
    func scheduleOutcomes() -> [String: [String: String]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let prefix = f.string(from: Date()) + "|"
        let all = Self.loadFiredSchedulesForUI(defaults: defaults)
        return all.filter { $0.key.hasPrefix(prefix) }
    }

    nonisolated private static func loadFiredSchedulesForUI(defaults: UserDefaults) -> [String: [String: String]] {
        guard let raw = defaults.string(forKey: DataEngine.defaultsScheduleFiredKey),
              let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    var planRows: [PlanRow] {
        let outcomes = scheduleOutcomes()
        return allAccounts.map { r in
            let cfg = readConfig(r.plugin)
            let canCall = r.canCall
            let trigEnabled = r.enabled && canCall && !cfg.scheduleTimes.isEmpty
                && !engine.triggerDisabledSlugs.contains(r.id)
            var outcome: String?
            if let dict = outcomes["\(dayKey())|\(r.id)"],
               let last = dict.max(by: { $0.key < $1.key }) {
                switch last.value {
                case "fired": outcome = "\(last.key) 已登记，调用结果未知"
                case "succeeded": outcome = "\(last.key) 调用成功"
                case "failed": outcome = "\(last.key) 调用失败"
                case "uncertain": outcome = "\(last.key) 结果不确定，可能已消费"
                case "skipped:busy": outcome = "\(last.key) 跳过：调用繁忙"
                case "skipped:disabled": outcome = "\(last.key) 跳过：账号或计划已停用"
                default: outcome = "\(last.key) 调用结果未知"
                }
            }
            let pausedByAccount = !r.enabled && canCall && !cfg.scheduleTimes.isEmpty
                && !engine.triggerDisabledSlugs.contains(r.id)
            return PlanRow(slug: r.id, name: r.name, providerName: providerName(for: r),
                           accent: r.plugin.manifest.accent, icon: r.plugin.manifest.icon,
                           canCall: canCall, enabled: trigEnabled, pausedByAccount: pausedByAccount,
                           times: cfg.scheduleTimes, lastOutcome: outcome)
        }
    }

    private func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: 草稿守卫

    private func clearDraft() {
        draft = nil; errors = [:]; topError = ""
    }

    /// dirty 则弹确认; 返回 true = 可继续
    func leaveGuard() -> Bool {
        guard let d = draft, d.dirty || d.isNew else { return true }
        if let confirmDiscardChanges { return confirmDiscardChanges() }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的修改？"
        alert.informativeText = "当前草稿尚未保存，离开后变更将丢失。"
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "继续编辑")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func flash(_ text: String, error: Bool) {
        toast = Toast(text: text, isError: error)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
