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
    @Published private(set) var registryErrors: [String: String] = [:]
    @Published private(set) var nodeMissing = false
    @Published private(set) var lastRefresh: Date?

    private let hudDir: URL
    private let bundleDir: URL?
    private let userDir: URL
    private let runner: ProviderRunner
    private let defaults: UserDefaults
    private var timer: Timer?

    static let defaultsNodeKey = "tokenhud.nodePath"

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
        reloadRegistry()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }
        Task { await refreshNow() }
    }

    func reloadRegistry() {
        let (plugins, errors) = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir)
        registryErrors = errors
        let now = Date().timeIntervalSince1970 * 1000
        states = plugins.filter(\.manifest.isEnabled).map {
            let cache = readCache(slug: $0.slug, manifest: $0.manifest)
            return ProviderState(slug: $0.slug, manifest: $0.manifest, cache: cache,
                                 isStale: !HUDFmt.isFresh(cache, interval: $0.manifest.interval, now: now))
        }
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
            lastRefresh = Date()
            return
        }
        // 并行刷过期家; 结果收齐后回 MainActor 统一落盘/更新内存态
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
