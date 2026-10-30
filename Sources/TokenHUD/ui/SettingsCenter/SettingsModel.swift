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
            let k = draftKey.trimmingCharacters(in: .whitespaces)
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

    /// P1-6 开关确认判定 (纯函数): off→on 且确认未给 → 需要弹消费确认
    /// (on→on / off→off / on→off / 新建草稿直接 on 不算 — 新建时 pickTemplate 已默认 off)
    static func needsTriggerConfirm(base: Bool, current: Bool, isNew: Bool) -> Bool {
        !isNew && !base && current
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
        if manifest.queryUrl != nil || manifest.cacheFile != nil { return .configured }
        return .notIntegrated
    }

    /// 模型调用能力: manifest 有 refreshUrl (模板锁定) = configured;
    /// 模板实例无 refreshUrl = notSupported (供应商声明层面就没有该端点);
    /// 通用自定义 = notConfigured (服务地址未填时可补)
    static func call(manifest: ProviderManifest, configUrl: String) -> CapabilityStatus {
        if let r = manifest.refreshUrl, !r.isEmpty { return .configured }
        if manifest.template != nil { return .notSupported }
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

    var dirty: Bool { values != base }
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
    /// P1-10 执行性配置完整 (key/url 齐) — false = 「未配置」徽章, 依赖配置的开关已强制 off
    let isConfigured: Bool

    var id: String { plugin.slug }
    var name: String { plugin.manifest.fullName }
    /// 有 queryUrl = 可查额度 (GPT/Cline 也有); 脚本型实例由 fetch.sh 直查, 由 cacheFile 声明
    var canQuery: Bool { plugin.manifest.queryUrl != nil || plugin.manifest.cacheFile != nil }
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

    /// 列表状态点: (色, 文案)
    var status: (Color, String) {
        if !isConfigured { return (Palette.warn, "未配置") }
        if !autoQuery { return (Palette.warn, "自动查询关") }
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
            case .trigger: return "自动触发"
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

    @Published var search = ""
    @Published var selected: String? { didSet { persistSelection() } }
    @Published var tab: Tab = .quota { didSet { defaults.set(tab.rawValue, forKey: SettingsPersist.tabKey) } }
    @Published var showingTemplates = false
    @Published var draft: Draft?
    @Published var errors: [String: String] = [:]
    @Published var topError = ""
    @Published var running: Set<String> = []
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
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.hudDir = hudDir
        self.userDir = userDir
        self.settingsURL = settingsURL
        self.bundleDir = bundleDir
        self.defaults = defaults
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

    var accounts: [AccountRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return engine.allPlugins
            .filter { p in
                q.isEmpty || p.manifest.fullName.lowercased().contains(q)
                    || p.manifest.label.lowercased().contains(q)
            }
            .map { p in
                AccountRow(plugin: p,
                           state: engine.states.first { $0.slug == p.slug } ?? cachedState(for: p),
                           autoQuery: !engine.disabledSlugs.contains(p.slug),
                           isConfigured: Self.configured(p, readConfig: readConfig))
            }
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
                          isConfigured: Self.configured(p, readConfig: readConfig))
    }

    /// P1-10 执行性配置完整判定 (静态, 供 AccountRow 构建)
    nonisolated private static func configured(_ p: PluginProvider,
                                               readConfig: (PluginProvider) -> ProviderConfig) -> Bool {
        guard p.manifest.authStyle == "apikey" else { return true }  // 本机凭证型不缺配置
        let cfg = readConfig(p)
        let key = cfg.queryKey.isEmpty ? cfg.refreshKey : cfg.queryKey
        if key.isEmpty { return false }
        // 通用自定义型: url 也必须在 (manifest.queryUrl 或 auth.apiUrl)
        if p.manifest.template == nil && p.manifest.queryUrl == nil && cfg.queryUrl.isEmpty {
            return false
        }
        return true
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
        if let t = d.template { return engine.template(bySlug: t)?.manifest }
        return nil
    }

    func draftCanCall() -> Bool { draftManifest()?.refreshUrl != nil }
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

    func selectAccount(_ slug: String) {
        guard leaveGuard() else { return }
        draft = nil; errors = [:]; topError = ""
        selected = slug
        showingTemplates = false
        tab = .quota
    }

    func openTemplates() {
        guard leaveGuard() else { return }
        clearDraft()
        showingTemplates = true
    }

    func startEdit() {
        guard let row = current else { return }
        let p = row.plugin
        let cfg = readConfig(p)
        let existingKey = cfg.queryKey.isEmpty ? cfg.refreshKey : cfg.queryKey
        let v = DraftValues(name: p.manifest.fullName,
                            url: p.manifest.queryUrl ?? cfg.queryUrl,
                            key: existingKey.isEmpty ? "" : existingKey,
                            model: cfg.testModel.isEmpty ? p.manifest.refreshModel : cfg.testModel,
                            prompt: cfg.testPrompt,
                            proto: cfg.refreshProtocol,
                            autoQuery: !engine.disabledSlugs.contains(p.slug),
                            autoTrigger: !engine.triggerDisabledSlugs.contains(p.slug)
                                && p.manifest.refreshUrl != nil,
                            times: cfg.scheduleTimes)
        draft = Draft(slug: p.slug, template: p.manifest.template, isNew: false, values: v, base: v)
        draft?.hasExistingKey = !existingKey.isEmpty
        errors = [:]; topError = ""
    }

    func pickTemplate(_ choice: TemplateChoice) {
        guard leaveGuard() else { return }
        let m = choice.manifest
        // 脚本型模板的查询地址在 auth 模板的 apiUrl 里, 只读展示用
        let urlHint = m?.queryUrl ?? templateAuthURL(choice.id)
        let v = DraftValues(name: (m?.fullName ?? choice.label) + " 新账号",
                            url: urlHint,
                            key: "",
                            model: m?.testModel ?? "",
                            prompt: m?.testPrompt ?? "回复 OK 即视为连通。",
                            proto: m?.refreshProtocol ?? choice.proto ?? "openai",
                            autoQuery: true,
                            autoTrigger: false,
                            times: [])
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
        var errs = SettingsValidation.configErrors(
            name: d.values.name, key: d.values.key, url: d.values.url,
            authStyle: draftAuthStyle(), builtin: draftBuiltin(),
            hasExistingKey: d.isNew ? false : d.hasExistingKey)
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
            let alert = NSAlert()
            alert.messageText = "开启模型定时调用？"
            let name = values.name.trimmingCharacters(in: .whitespaces)
            alert.informativeText = "开启后 \(name) 将在设定时间点自动发送一次模型调用以刷新额度窗口，每次都会消耗该账号额度。确定开启？"
            alert.addButton(withTitle: "开启")
            alert.addButton(withTitle: "保持关闭")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn {
                values.autoTrigger = false
            }
        }
        do {
            // P1-10: 执行性缺失可保存 (账号标未配置), 但依赖配置的开关强制 off + 提示
            let incomplete = SettingsValidation.isIncomplete(
                name: values.name, key: values.key, url: values.url,
                authStyle: draftAuthStyle(), builtin: draftBuiltin(),
                hasExistingKey: d.isNew ? false : d.hasExistingKey)
            if incomplete {
                values.autoQuery = false
                values.autoTrigger = false
            }
            let slug = d.isNew ? try create(values: values, draft: d)
                               : try update(values: values, draft: d)
            engine.reloadRegistry()
            clearDraft()
            showingTemplates = false
            selected = slug
            tab = .quota
            flash(incomplete
                  ? "已保存（未配置：凭证或地址缺失，自动查询与定时调用已关闭）"
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

    private func create(values: DraftValues, draft d: Draft) throws -> String {
        let name = values.name.trimmingCharacters(in: .whitespaces)
        // 凭据型模板: 空 Key 由校验已挡; 此处只保证落盘不写入空替换
        let base = PluginGenerator.slugify(name)
        let existing = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir).plugins.map(\.slug)
        var slug = base
        var n = 2
        while existing.contains(slug) || FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        var cfg = ProviderConfig()
        cfg.queryUrl = values.url
        cfg.queryKey = values.key
        cfg.refreshKey = values.key
        cfg.testModel = values.model
        cfg.testPrompt = values.prompt
        cfg.refreshProtocol = values.proto
        cfg.scheduleTimes = values.times
        if let tslug = d.template, let tmpl = engine.template(bySlug: tslug) {
            let manifest = try PluginGenerator.instantiate(template: tmpl, slug: slug, name: name,
                                                           into: userDir, hudDir: hudDir)
            guard let af = manifest.authFile.map(PluginGenerator.expandPath) else { return slug }
            var merged = ProviderConfigStore.read(authFile: af, manifest: manifest)
            merged.queryKey = cfg.queryKey
            merged.refreshKey = cfg.refreshKey
            merged.testModel = cfg.testModel
            merged.testPrompt = cfg.testPrompt
            merged.scheduleTimes = cfg.scheduleTimes
            try ProviderConfigStore.write(merged, manifest: manifest, to: af)
            applyToggles(slug: slug, values: values, manifest: manifest)
            return slug
        }
        // 通用自定义: manifest + one-api 脚本 + auth
        let authPath = PluginGenerator.authPath(slug: slug, hudDir: hudDir)
        let manifest = PluginGenerator.customManifest(name: name, config: cfg, authFile: authPath)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try PluginGenerator.writePlugin(slug: slug, manifest: manifest,
                                        script: PluginGenerator.oneAPIFetchScript(slug: slug), into: userDir)
        let af = PluginGenerator.expandPath(authPath)
        try FileManager.default.createDirectory(at: af.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: af.path) {
            try ProviderConfigStore.createCustom(slug: slug, to: af)
        }
        try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
        applyToggles(slug: slug, values: values, manifest: manifest)
        return slug
    }

    private func update(values: DraftValues, draft d: Draft) throws -> String {
        guard let slug = d.slug,
              let p = engine.allPlugins.first(where: { $0.slug == slug }) else { return d.slug ?? "" }
        let name = values.name.trimmingCharacters(in: .whitespaces)
        var cfg = readConfig(p)
        // P1-9: Key 三态落盘 — clear→清空, 空+已有→保持原值 (nil 不动), 有值→替换
        let existingKey = cfg.queryKey.isEmpty ? cfg.refreshKey : cfg.queryKey
        let intent: SettingsValidation.KeyIntent = values.clearKeyIntent ? .clear : .replace
        if let resolved = SettingsValidation.resolveKey(draftKey: values.key, existingKey: existingKey,
                                                        intent: intent) {
            cfg.queryKey = resolved
            cfg.refreshKey = resolved
        }
        cfg.queryUrl = values.url
        cfg.testModel = values.model
        cfg.testPrompt = values.prompt
        cfg.scheduleTimes = values.times
        guard let af = authURL(p) else { throw NSError(domain: "TokenHUD", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "凭证文件路径缺失"]) }
        if p.manifest.template == nil {
            // 通用: name/address/protocol 进 manifest, 同步脚本
            cfg.refreshProtocol = values.proto
            cfg.refreshUrl = ImportCandidateTriggerURL(values.url, proto: values.proto)
            cfg.refreshHeader = values.proto == "anthropic"
                ? "Authorization: Bearer <key>\nanthropic-version: 2023-06-01"
                : "Authorization: Bearer <key>"
            let manifest = PluginGenerator.customManifest(
                name: name, config: cfg,
                authFile: PluginGenerator.authPath(slug: slug, hudDir: hudDir))
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest,
                                            script: PluginGenerator.oneAPIFetchScript(slug: slug),
                                            into: userDir)
            try ProviderConfigStore.write(cfg, manifest: manifest, to: af)
        } else {
            var m = p.manifest
            m.displayName = name
            let script = (try? String(contentsOf: userDir.appendingPathComponent(slug + "/fetch.sh"),
                                      encoding: .utf8)) ?? ""
            try PluginGenerator.writePlugin(slug: slug, manifest: m, script: script, into: userDir)
            try ProviderConfigStore.write(cfg, manifest: m, to: af)
        }
        if var m = engine.allPlugins.first(where: { $0.slug == slug })?.manifest {
            m.displayName = name
            applyToggles(slug: slug, values: values, manifest: m)
        } else {
            applyToggles(slug: slug, values: values, manifest: p.manifest)
        }
        return slug
    }

    private func applyToggles(slug: String, values: DraftValues, manifest: ProviderManifest) {
        engine.setTracking(slug, enabled: values.autoQuery)
        let callable = manifest.refreshUrl != nil
        engine.setTriggerEnabled(slug, enabled: callable && values.autoTrigger)
    }

    private func ImportCandidateTriggerURL(_ base: String, proto: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        if proto == "anthropic" {
            return b.hasSuffix("/v1") ? b + "/messages" : b + "/v1/messages"
        }
        return b.hasSuffix("/v1") ? b + "/chat/completions" : b + "/v1/chat/completions"
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
            flash("未配置调用端点，无法发送测试调用", error: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "发送一次测试调用？"
        alert.informativeText = "将消耗 \(row.plugin.manifest.fullName) 的额度，使用 \(row.plugin.manifest.refreshProtocol ?? "openai") 协议；调用结果不代表 5 小时窗口会重置。"
        alert.addButton(withTitle: "发送测试")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !running.contains(slug) else { return }
        running.insert(slug)
        flash("测试调用已发送…", error: false)
        let started = Date()
        Task {
            // P1-4 并发位: 同账号已有调用在飞 → busy 提示 (不排队)
            guard await engine.callSlots.acquire(slug) else {
                running.remove(slug)
                flash("该账号已有调用进行中，请稍候再试", error: true)
                return
            }
            var err: String?
            if let af = authURL(row.plugin), let m = engine.allPlugins.first(where: { $0.slug == slug })?.manifest {
                err = await RefreshTrigger.trigger(manifest: m, authFile: af)
            } else {
                err = "凭证文件缺失"
            }
            await engine.callSlots.release(slug)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            running.remove(slug)
            // P1-5: send() 成功返回 "✓ …" 前缀; 其他 (含网络不确定/HTTP 错/空 body) 均按失败/异常展示
            let ok = err?.hasPrefix("✓") == true
            lastRun[slug] = (ok, ms, Date())
            flash(ok ? "测试调用成功（\(ms) ms）" : "测试调用失败：\(err ?? "")", error: !ok)
        }
    }

    /// P1-6 草稿测试调用: 用草稿当前配置显式发送, 不落盘 (盘上配置不变)
    func testCallDraft(values: DraftValues) {
        var cfg = ProviderConfig()
        cfg.refreshProtocol = values.proto
        // 目标端点: 模板实例用 manifest.refreshUrl (锁定); 通用草稿由服务地址按协议推导
        if let r = draftManifest()?.refreshUrl {
            cfg.refreshUrl = r
        } else if !values.url.trimmingCharacters(in: .whitespaces).isEmpty {
            cfg.refreshUrl = ProviderImporter.triggerURLForTest(
                values.url.trimmingCharacters(in: .whitespaces), values.proto)
        }
        cfg.refreshHeader = values.proto == "anthropic"
            ? "Authorization: Bearer <key>\nanthropic-version: 2023-06-01"
            : "Authorization: Bearer <key>"
        cfg.testModel = values.model
        cfg.testPrompt = values.prompt
        // 凭证: 优先草稿输入框 (空 = 已有账号沿用盘上 Key)
        let draftKey = values.key.trimmingCharacters(in: .whitespaces)
        if !draftKey.isEmpty {
            cfg.refreshKey = draftKey
        } else if let d = draft, let slug = d.slug,
                  let p = engine.allPlugins.first(where: { $0.slug == slug }) {
            let disk = readConfig(p)
            cfg.refreshKey = disk.refreshKey.isEmpty ? disk.queryKey : disk.refreshKey
        }
        let label = draftManifest()?.fullName ?? "草稿配置"
        let alert = NSAlert()
        alert.messageText = "用当前草稿发送测试调用？"
        alert.informativeText = "使用草稿配置（未保存，盘上账号配置不受影响），将消耗 \(label) 的额度，使用 \(values.proto) 协议。"
        alert.addButton(withTitle: "发送测试")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let slug = draft?.slug ?? "draft"
        guard !running.contains(slug) else { flash("已有调用进行中，请稍候", error: true); return }
        running.insert(slug)
        flash("草稿测试调用已发送…", error: false)
        let started = Date()
        Task {
            // P1-4 并发位: 同账号 (或草稿目标账号) 已占用 → busy 提示
            guard await engine.callSlots.acquire(slug) else {
                running.remove(slug)
                flash("该账号已有调用进行中，请稍候再试", error: true)
                return
            }
            let err = await RefreshTrigger.testRefresh(config: cfg)
            await engine.callSlots.release(slug)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            running.remove(slug)
            let ok = err?.hasPrefix("✓") == true
            flash(ok ? "草稿测试调用成功（\(ms) ms）" : "草稿测试调用失败：\(err ?? "")", error: !ok)
        }
    }

    func delete(_ slug: String) {
        guard let p = engine.allPlugins.first(where: { $0.slug == slug }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(p.manifest.fullName)?"
        alert.informativeText = "将移除插件目录, 不可撤销"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if p.manifest.template != nil { engine.markTemplateDeleted(slug) }
        try? PluginGenerator.removePlugin(slug: slug, in: userDir)
        if let af = authURL(p) { try? FileManager.default.trashItem(at: af, resultingItemURL: nil) }
        // 清理残留: cache 文件 (HUD 不再显示已删账号旧值) + envs.json 摘除该账号条目
        try? FileManager.default.removeItem(at: DataEngine.cachePath(for: p, hudDir: hudDir))
        removeEnvsEntry(name: p.manifest.name)
        draft = nil
        selected = engine.allPlugins.first { $0.slug != slug }?.slug
        engine.reloadRegistry()
        flash("已删除 \(p.manifest.fullName)", error: false)
    }

    /// envs.json 摘除已删账号条目 (statusline 不再读它的 cache)
    private func removeEnvsEntry(name: String) {
        let envsURL = hudDir.appendingPathComponent("envs.json")
        guard let existing = (try? Data(contentsOf: envsURL))
            .flatMap({ try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) }),
              existing.keys.contains(name) else { return }
        var merged = existing
        merged.removeValue(forKey: name)
        try? HUDSync.writeEnvs(merged, to: envsURL)
    }

    func syncHUD() {
        do {
            engine.installScripts()
            let plugins = engine.allPlugins
            let builtin = Set(plugins.filter { $0.manifest.template != nil }.map { $0.manifest.name })
            let new = HUDSync.envsDict(plugins: plugins, hudDir: hudDir, builtinNames: builtin)
            let envsURL = hudDir.appendingPathComponent("envs.json")
            let existing = (try? Data(contentsOf: envsURL))
                .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
            try HUDSync.writeEnvs(HUDSync.mergeEnvs(existing: existing, new: new, builtinNames: builtin),
                                  to: envsURL)
            let keys = plugins.filter { $0.manifest.isEnabled && !engine.disabledSlugs.contains($0.slug) }
                .map(\.manifest.name)
            let settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any]
            let current = (settings?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
            try HUDSync.patchSettings(settingsURL: settingsURL,
                                      accountEnvs: HUDSync.mergeAccountEnvs(current: current, keys: keys),
                                      statuslinePath: hudDir.appendingPathComponent("statusline.mjs").path)
            flash("已写入 Claude Code HUD（下次渲染生效）", error: false)
        } catch {
            flash("写入 HUD 失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: 草稿守卫

    private func clearDraft() {
        draft = nil; errors = [:]; topError = ""
    }

    /// dirty 则弹确认; 返回 true = 可继续
    func leaveGuard() -> Bool {
        guard let d = draft, d.dirty || d.isNew else { return true }
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
