import Foundation

enum PluginGenerator {
    /// 小写；空格/下划线→"-"；非法字符逐个→"-"（连续非法→连续"-"，不 trim）；空则 "custom"
    static func slugify(_ name: String) -> String {
        let s = String(name.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isLowercase) || ch.isNumber || ch == "-" ? ch : "-"
        })
        return s.isEmpty ? "custom" : s
    }

    /// 自定义供应商 manifest: 协议抓取配置来自编辑弹窗 config (manifest 驱动, 主框架通用)
    static func customManifest(name: String, config: ProviderConfig, authFile: String) -> ProviderManifest {
        ProviderManifest(
            name: name, label: name, displayName: name,
            buckets: ["five_hour": "5h", "seven_day": "周", "monthly": "月"],
            authFile: authFile,
            testModel: config.testModel.isEmpty ? nil : config.testModel,
            testPrompt: config.testPrompt.isEmpty ? nil : config.testPrompt,
            queryUrl: config.queryUrl.isEmpty ? nil : config.queryUrl,
            queryAuth: "bearer",
            refreshUrl: config.refreshUrl.isEmpty ? nil : config.refreshUrl,
            refreshProtocol: config.refreshProtocol,
            refreshAuth: "bearer",
            refreshHeader: config.refreshHeader.isEmpty ? nil : config.refreshHeader,
            quotaMode: config.quotaMode)
    }

    // MARK: - 类型模板 → 账号实例

    /// auth 文件路径: hudDir 在 HOME 下用 ~ 形式, 否则绝对路径 (测试传 tmp 即隔离)
    static func authPath(slug: String, hudDir: URL) -> String {
        instancePath(slug: slug, hudDir: hudDir, suffix: "usage-auth.json")
    }

    static func cachePath(slug: String, hudDir: URL) -> String {
        instancePath(slug: slug, hudDir: hudDir, suffix: "usage-cache.json")
    }

    private static func instancePath(slug: String, hudDir: URL, suffix: String) -> String {
        let home = NSHomeDirectory()
        let rel = hudDir.path.hasPrefix(home) ? "~" + hudDir.path.dropFirst(home.count) : hudDir.path
        return rel + "/.\(slug)-\(suffix)"
    }

    /// `~` 前缀展开为 HOME, 其余按绝对路径
    static func expandPath(_ p: String) -> URL {
        p.hasPrefix("~") ? URL(fileURLWithPath: NSHomeDirectory() + String(p.dropFirst()))
                         : URL(fileURLWithPath: p)
    }

    /// 从类型模板实例化账号插件 (幂等): manifest 派生 + fetch.sh {SLUG} 替换 + auth 模板复制 (不覆盖已有 auth)
    /// 返回实例 manifest, 调用方继续用 ProviderConfigStore.write 写凭证
    @discardableResult
    static func instantiate(template: PluginProvider, slug: String, name: String,
                            into root: URL, hudDir: URL) throws -> ProviderManifest {
        let t = template.manifest
        let manifest = ProviderManifest(
            name: t.name, label: t.label, displayName: name,
            intervalSec: t.intervalSec,
            buckets: t.buckets,
            cacheFile: cachePath(slug: slug, hudDir: hudDir),
            authFile: authPath(slug: slug, hudDir: hudDir),
            needsCredential: t.needsCredential,
            testModel: t.testModel,
            testPrompt: t.testPrompt,
            queryUrl: t.queryUrl,
            queryAuth: t.queryAuth,
            queryKeyField: t.queryKeyField,
            refreshUrl: t.refreshUrl,
            refreshProtocol: t.refreshProtocol,
            refreshAuth: t.refreshAuth,
            refreshHeader: t.refreshHeader,
            template: template.slug,
            accent: t.accent, icon: t.icon, authMode: t.authMode, quotaMode: "script")
        // fetch.sh: 读模板脚本, {SLUG} 替换后写入实例目录
        let script = (try? String(contentsOf: template.dir.appendingPathComponent("fetch.sh"), encoding: .utf8))
            .map { $0.replacingOccurrences(of: "{SLUG}", with: slug) }
            ?? ""
        try writePlugin(slug: slug, manifest: manifest, script: script, into: root)
        // auth 模板 → 实例 auth (不覆盖: 迁移保凭证, 新建给缺省抓取配置)
        // auth 模板 -> 实例 auth (不覆盖: 迁移保凭证, 新建给缺省抓取配置)
        guard let authFile = manifest.authFile else { return manifest }
        let authURL = expandPath(authFile)
        let fm = FileManager.default
        try? fm.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: authURL.path),
           let tpl = try? Data(contentsOf: template.dir.appendingPathComponent("auth-template.json")) {
            try tpl.write(to: authURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        }
        return manifest
    }

    /// 读 auth 文件版: url/key 运行时取自 .{slug}-usage-auth.json, 编辑弹窗保存后自动生效
    static func oneAPIFetchScript(slug: String) -> String {
        """
        #!/bin/zsh
        set -eu
        HUD_DIR="${TOKENHUD_HUD_DIR:-$HOME/.claude/hud}"
        export TOKENHUD_AUTH_FILE="${TOKENHUD_AUTH_FILE:-$HUD_DIR/.\(slug)-usage-auth.json}"
        exec "${TOKENHUD_NODE:-node}" "$HUD_DIR/generic-usage-provider.mjs"
        """
    }

    static func writePlugin(slug: String, manifest: ProviderManifest, script: String, into root: URL) throws {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        try script.write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("fetch.sh").path)
    }

    static func removePlugin(slug: String, in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(slug, isDirectory: true))
    }
}
