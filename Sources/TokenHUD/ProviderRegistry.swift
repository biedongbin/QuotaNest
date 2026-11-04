import Foundation

enum ProviderRegistry {
    static func isValidSlug(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    /// 扫单个插件根目录: <dir>/<slug>/manifest.json
    static func scan(dir: URL) -> [PluginProvider] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.hasDirectoryPath && isValidSlug($0.lastPathComponent) }
            .compactMap { slugDir -> PluginProvider? in
                let mfile = slugDir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: mfile),
                      let m = try? JSONDecoder().decode(ProviderManifest.self, from: data)
                else { return nil }
                return PluginProvider(slug: slugDir.lastPathComponent, manifest: m, dir: slugDir)
            }
            .sorted { $0.slug < $1.slug }
    }

    /// 双源合并: bundle 内置 + 用户目录(同名覆盖), 返回错误清单 (slug -> 原因)
    static func load(bundleDir: URL?, userDir: URL) -> (plugins: [PluginProvider], errors: [String: String]) {
        var errors: [String: String] = [:]
        let fm = FileManager.default

        // 用户目录里 manifest 损坏的也要报出来(不能静默)
        if let entries = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) {
            for e in entries where e.hasDirectoryPath && isValidSlug(e.lastPathComponent) {
                let mfile = e.appendingPathComponent("manifest.json")
                let ok = (try? Data(contentsOf: mfile))
                    .flatMap { try? JSONDecoder().decode(ProviderManifest.self, from: $0) } != nil
                if !ok { errors[e.lastPathComponent] = "manifest.json 解析失败或缺失" }
            }
        }

        var merged: [String: PluginProvider] = [:]
        for p in (bundleDir.map(scan(dir:)) ?? []) where p.manifest.autoCreateDefault != false {
            merged[p.slug] = p
        }
        for p in scan(dir: userDir) { merged[p.slug] = p }
        return (Array(merged.values).sorted { $0.slug < $1.slug }, errors)
    }
}
