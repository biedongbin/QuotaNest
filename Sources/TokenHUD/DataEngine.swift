import Foundation
import SwiftUI

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

    /// generatedAt(ms epoch) 距 now 未超 interval 秒
    static func isFresh(_ cache: UsageCache?, interval: Int, now: Double) -> Bool {
        guard let g = cache?.generatedAt else { return false }
        return now - g < Double(interval) * 1000
    }
}

// MARK: - 状态

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

    static let defaultsNodeKey = "tokenhud.nodePath"
    static let defaultsIconKey = "tokenhud.iconProvider"
    static let defaultsDisabledKey = "tokenhud.disabledProviders"
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
    nonisolated static func installMjs(bundleDir: URL?, hudDir: URL) {
        guard let bundleDir else { return }
        let srcDir = bundleDir.deletingLastPathComponent().appendingPathComponent("mjs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) else { return }
        let fm = FileManager.default
        for f in files where f.pathExtension == "mjs" {
            let dst = hudDir.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: f, to: dst)
        }
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
    /// 记录上次触发 (HH:MM), 避免同分钟重复触发
    private var lastScheduledTrigger: [String: String] = [:]
    /// scheduleTimes 缓存 (reloadRegistry 时重建, 免每 10s 重复读 auth 文件)
    private var cachedSchedules: [(slug: String, manifest: ProviderManifest, authFile: URL, times: [String])] = []

    private func checkSchedules() {
        let cal = Calendar.current
        let now = Date()
        let hhmm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        for sch in cachedSchedules {
            guard sch.times.contains(hhmm) else { continue }
            if lastScheduledTrigger[sch.slug] == hhmm { continue } // 本分钟已触发
            lastScheduledTrigger[sch.slug] = hhmm
            // 走 trigger() (auth 无 testModel 时回退 manifest.refreshModel), 不能直呼 testRefresh
            Task { @MainActor in
                _ = await RefreshTrigger.trigger(manifest: sch.manifest, authFile: sch.authFile)
            }
        }
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
        // MainActor 上下文先筛过期家 (快照), 避免闭包跨隔离访问 states
        let due: [(String, PluginProvider)] = states.compactMap { st in
            guard !HUDFmt.isFresh(st.cache, interval: st.manifest.interval, now: now) else { return nil }
            return (st.slug, PluginProvider(slug: st.slug, manifest: st.manifest,
                                            dir: pluginDir(slug: st.slug)))
        }
        guard !due.isEmpty else {
            return // 无家过期, 不更新 lastRefresh (避免假"0s前")
        }
        await fetch(due, now: now)
    }

    /// 强制刷新单家 (忽略 fresh 状态), 用于"刷新额度"后立即查余额更新
    func forceRefresh(slug: String) async {
        guard let st = states.first(where: { $0.slug == slug }) else { return }
        let plugin = PluginProvider(slug: st.slug, manifest: st.manifest, dir: pluginDir(slug: st.slug))
        await fetch([(slug, plugin)], now: Date().timeIntervalSince1970 * 1000)
    }

    /// 立刻刷新: 对全部启用供应商发 API 请求触发额度计算, 再强制查余额+重置时间
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
                    await self?.forceRefresh(slug: slug)
                }
            }
        }
    }

    /// 并行刷给定家, 结果收齐后回 MainActor 统一落盘/更新内存态
    private func fetch(_ due: [(String, PluginProvider)], now: Double) async {
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
            apply(slug: slug, fetched: cache, now: now)
        }
        lastRefresh = Date()
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
            // 失败: 保留旧值, 标 stale (旧值写盘也盖 stale 标记, 与 statusline 约定一致)
            var old = states[i].cache ?? UsageCache(generatedAt: now, fiveHour: nil, sevenDay: nil,
                                                    monthly: nil, error: "fetch", stale: true)
            old.stale = true
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
