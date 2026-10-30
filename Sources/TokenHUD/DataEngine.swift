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
    @Published private(set) var nodeMissing = false
    @Published private(set) var lastRefresh: Date?
    /// "立刻刷新"进行中 (状态栏图标显示 ⟳ 反馈)
    @Published private(set) var isRefreshingAll = false
    /// 图标默认显示哪家 (slug); nil = 全部取最高
    @Published var iconProviderSlug: String?
    /// 关闭用量跟踪的供应商 (slug 集合), UserDefaults 持久化
    @Published private(set) var disabledSlugs: Set<String> = []
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
    private var timer: Timer?
    /// P1-4 模型调用并发位 (每账号 1 / 全局 2): 计划触发与测试调用共用
    let callSlots = CallSlots()

    static let defaultsNodeKey = "tokenhud.nodePath"
    static let defaultsIconKey = "tokenhud.iconProvider"
    static let defaultsDisabledKey = "tokenhud.disabledProviders"
    static let defaultsTriggerDisabledKey = "tokenhud.triggerDisabled.slugs"
    static let defaultsOrderKey = "tokenhud.providerOrder"
    static let defaultsDeletedKey = "tokenhud.deletedTemplates"

    init(hudDir: URL, bundleProvidersDir: URL?, userProvidersDir: URL,
         runner: ProviderRunner, defaults: UserDefaults = .standard) {
        self.hudDir = hudDir
        self.bundleDir = bundleProvidersDir
        self.userDir = userProvidersDir
        self.runner = runner
        self.defaults = defaults
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
        triggerDisabledSlugs = Set(defaults.stringArray(forKey: Self.defaultsTriggerDisabledKey) ?? [])
        providerOrder = defaults.stringArray(forKey: Self.defaultsOrderKey) ?? []
        deletedTemplates = Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? [])
        // 固化引擎 (mjs) 随 App 分发, 启动覆盖安装 (幂等升级); 再迁移模板缺省实例
        Self.installMjs(bundleDir: bundleDir, hudDir: hudDir)
        migrateAccounts()
        reloadRegistry()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
                self?.checkSchedules()
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
    func migrateAccounts() {
        guard let bundleDir else { return }
        let fm = FileManager.default
        for t in ProviderRegistry.scan(dir: bundleDir) {
            if Set(defaults.stringArray(forKey: Self.defaultsDeletedKey) ?? []).contains(t.slug) { continue }
            let dir = userDir.appendingPathComponent(t.slug, isDirectory: true)
            let manifestPath = dir.appendingPathComponent("manifest.json").path
            if fm.fileExists(atPath: manifestPath) {
                // 模板升级同步: 按当前模板刷新实例 manifest 能力字段, 保留用户 displayName
                // (auth 不动: 凭证/抓取配置/定时保留)
                let displayName = (try? JSONDecoder().decode(ProviderManifest.self,
                                                             from: Data(contentsOf: dir.appendingPathComponent("manifest.json"))))?
                    .displayName ?? t.manifest.fullName
                _ = try? PluginGenerator.instantiate(template: t, slug: t.slug,
                                                     name: displayName, into: userDir,
                                                     hudDir: hudDir)
            } else {
                _ = try? PluginGenerator.instantiate(template: t, slug: t.slug,
                                                     name: t.manifest.fullName, into: userDir,
                                                     hudDir: hudDir)
            }
            _ = fm
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

    private func checkSchedules() {
        let cal = Calendar.current
        let now = Date()
        let hhmm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        var fired = loadFiredSchedules()
        // 只保留今天与昨天的键 (防字典无限增长; 昨天保留兜 DST 深夜场景)
        let todayPrefix = Self.dayPrefix(now), yesterdayPrefix = Self.dayPrefix(cal.date(byAdding: .day, value: -1, to: now) ?? now)
        fired = fired.filter { k, _ in k.hasPrefix(todayPrefix) || k.hasPrefix(yesterdayPrefix) }
        for sch in cachedSchedules {
            guard sch.times.contains(hhmm) else { continue }
            guard !triggerDisabledSlugs.contains(sch.slug) else { continue } // 定时触发已关 (与跟踪开关独立)
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
                _ = await RefreshTrigger.trigger(manifest: sch.manifest, authFile: sch.authFile)
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
        registryErrors = errors
        allPlugins = plugins
        // 类型模板 = bundle 里的只读定义 (添加供应商选类型/编辑能力判定用)
        templates = bundleDir.map { ProviderRegistry.scan(dir: $0) } ?? []
        // scheduleTimes 缓存重建 (编辑保存后 reload 即刷新)
        cachedSchedules = plugins.compactMap { p in
            let auth = authURL(for: ProviderState(slug: p.slug, manifest: p.manifest, cache: nil, isStale: false))
            guard let auth else { return nil }
            return (p.slug, p.manifest, auth, ProviderConfigStore.read(authFile: auth, manifest: p.manifest).scheduleTimes)
        }
        let now = Date().timeIntervalSince1970 * 1000
        states = plugins
            .filter { $0.manifest.isEnabled && !disabledSlugs.contains($0.slug) }
            .sorted { orderIndex($0.slug) < orderIndex($1.slug) }
            .map {
                let cache = readCache(slug: $0.slug, manifest: $0.manifest)
                return ProviderState(slug: $0.slug, manifest: $0.manifest, cache: cache,
                                     isStale: !HUDFmt.isFresh(cache, interval: $0.manifest.interval, now: now))
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

    func refreshNow() async {
        let now = Date().timeIntervalSince1970 * 1000
        // MainActor 上下文先筛过期家 (按尝试时间: 失败也会前移 lastAttemptAt, 免 10s timer 对失败家反复重刷)
        let due: [(String, PluginProvider)] = states.compactMap { st in
            guard !HUDFmt.isAttemptFresh(st.cache, interval: st.manifest.interval, now: now) else { return nil }
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
        // 核对: 查询期间账号被删/凭证被改 → 丢弃 (FR-05.3)
        let rev0 = Self.configRevision(slug: slug, manifest: plugin.manifest)
        let now = Date().timeIntervalSince1970 * 1000
        let fetched = await runner.run(plugin)
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
    private func fetch(_ due: [(String, PluginProvider)], now: Double, checkRevision: Bool) async {
        let revisions: [String: Double] = checkRevision
            ? Dictionary(uniqueKeysWithValues: due.map { ($0.0, Self.configRevision(slug: $0.0, manifest: $0.1.manifest)) })
            : [:]
        let results: [(String, UsageCache?)] = await withTaskGroup(of: (String, UsageCache?).self) { group in
            for (slug, plugin) in due {
                group.addTask { [runner] in
                    (slug, await runner.run(plugin))
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
        return (try? URL(fileURLWithPath: path.path)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
    }

    /// 错误码 → 人话 (缓存契约里的 error 字段值不变)
    nonisolated static func reason(for code: String) -> String {
        switch code {
        case "auth", "no-auth": return "缺凭证或凭证失效"
        case "fetch": return "查询无结果"
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
            writeCache(fetched, plugin: states[i])
            states[i].cache = fetched
            states[i].isStale = false
        } else {
            // 失败: 保留旧值与原 generatedAt (成功快照时间不因失败推进, FR-03.8),
            // 仅前移 lastAttemptAt — due 判定用 isAttemptFresh, 10s timer 不会反复重刷
            var old = states[i].cache ?? UsageCache(generatedAt: nil, fiveHour: nil, sevenDay: nil,
                                                    monthly: nil, error: "fetch", stale: true)
            old.stale = true
            old.lastAttemptAt = now
            if old.error == nil { old.error = "fetch" }
            states[i].cache = old
            states[i].isStale = true
            writeCache(old, plugin: states[i])
        }
    }

    private func readCache(slug: String, manifest: ProviderManifest) -> UsageCache? {
        let p = DataEngine.cachePath(for: PluginProvider(slug: slug, manifest: manifest, dir: hudDir),
                                     hudDir: hudDir)
        guard let data = try? Data(contentsOf: p) else { return nil }
        return try? JSONDecoder().decode(UsageCache.self, from: data)
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
