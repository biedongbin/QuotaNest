import Testing
import Foundation
@testable import QuotaNest

/// 类型模板 -> 账号实例: manifest 派生 / fetch.sh {SLUG} 替换 / auth 不覆盖 / mjs 安装 / 迁移不变量
struct InstanceTests {
    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenhud-instance-" + UUID().uuidString, isDirectory: true)
    }

    /// 假模板: manifest + fetch.sh({SLUG} 占位) + auth-template.json
    private func makeTemplate(slug: String, in tmp: URL) throws -> PluginProvider {
        let dir = tmp.appendingPathComponent("bundle").appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = ProviderManifest(
            name: "CC-Test", label: "TT", displayName: "TestType",
            buckets: ["five_hour": "5h"],
            needsCredential: true, testModel: "test-model",
            queryAuth: "jwt",
            refreshUrl: "https://x.example/v1/messages",
            refreshProtocol: "anthropic",
            refreshAuth: "bearer",
            refreshHeader: "Authorization: Bearer <key>",
            accent: "blue", icon: "brain")
        let enc = JSONEncoder()
        try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let script = "#!/bin/zsh\nexport USAGE_AUTH_FILE=\"$HOME/.claude/hud/.{SLUG}-usage-auth.json\"\ncat \"$HOME/.claude/hud/.{SLUG}-usage-cache.json\"\n"
        try script.write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let authTpl = "{\"apiUrl\": \"https://q.example\", \"headers\": {\"authorization\": \"\"}}"
        try authTpl.write(to: dir.appendingPathComponent("auth-template.json"), atomically: true, encoding: .utf8)
        return PluginProvider(slug: slug, manifest: manifest, dir: dir)
    }

    @Test func instantiateDerivesManifestAndScript() throws {
        let tmp = makeTmp()
        let tmpl = try makeTemplate(slug: "testtype", in: tmp)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        let m = try PluginGenerator.instantiate(template: tmpl, slug: "tt-work", name: "TT-工作", into: userDir, hudDir: hudDir)

        #expect(m.displayName == "TT-工作")
        #expect(m.template == "testtype")
        #expect(m.authFile?.hasSuffix(".tt-work-usage-auth.json") == true)
        #expect(m.cacheFile?.hasSuffix(".tt-work-usage-cache.json") == true)
        #expect(m.buckets == ["five_hour": "5h"])
        #expect(m.queryAuth == "jwt")
        #expect(m.refreshUrl == "https://x.example/v1/messages")
        #expect(m.accent == "blue")

        let script = try String(contentsOf: userDir.appendingPathComponent("tt-work/fetch.sh"), encoding: .utf8)
        #expect(!script.contains("{SLUG}"))
        #expect(script.contains(".tt-work-usage-auth.json"))

        let auth = try String(contentsOf: hudDir.appendingPathComponent(".tt-work-usage-auth.json"), encoding: .utf8)
        #expect(auth.contains("https://q.example"))
        cleanup(tmp)
    }

    @Test func instantiateDoesNotOverwriteExistingAuth() throws {
        let tmp = makeTmp()
        let tmpl = try makeTemplate(slug: "testtype", in: tmp)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        let auth = hudDir.appendingPathComponent(".tt-live-usage-auth.json")
        try "{\"secret\": \"keep-me\"}".write(to: auth, atomically: true, encoding: .utf8)

        _ = try PluginGenerator.instantiate(template: tmpl, slug: "tt-live", name: "TT", into: userDir, hudDir: hudDir)
        let after = try String(contentsOf: auth, encoding: .utf8)
        #expect(after.contains("keep-me"))
        #expect(!after.contains("q.example"))
        cleanup(tmp)
    }

    @Test @MainActor func migrateSkipsTombstoneAndIsIdempotent() throws {
        let tmp = makeTmp()
        _ = try makeTemplate(slug: "glm", in: tmp)
        let bundleDir = tmp.appendingPathComponent("bundle", isDirectory: true)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "instance-tests")!
        defaults.removePersistentDomain(forName: "instance-tests")
        defaults.set(["glm"], forKey: "quotanest.deletedTemplates")
        let runner = ProviderRunner(nodePath: "/usr/bin/true", logDir: hudDir)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: bundleDir,
                                userProvidersDir: userDir, runner: runner, defaults: defaults,
                                settingsURL: tmp.appendingPathComponent("settings.json"))
        engine.migrateAccounts()
        let m = "glm/manifest.json"
        #expect(!FileManager.default.fileExists(atPath: userDir.appendingPathComponent(m).path),
                "tombstone 模板不得迁移复活")

        defaults.set([], forKey: "quotanest.deletedTemplates")
        engine.migrateAccounts()
        #expect(FileManager.default.fileExists(atPath: userDir.appendingPathComponent(m).path))
        engine.migrateAccounts()
        let s1 = try String(contentsOf: userDir.appendingPathComponent("glm/fetch.sh"), encoding: .utf8)
        #expect(!s1.contains("{SLUG}"))
        cleanup(tmp)
    }

    @Test func installMjsCopiesAndUpgrades() throws {
        let tmp = makeTmp()
        let bundleDir = tmp.appendingPathComponent("bundle/anyprov", isDirectory: true)
        let mjsDir = bundleDir.deletingLastPathComponent().appendingPathComponent("mjs", isDirectory: true)
        try FileManager.default.createDirectory(at: mjsDir, withIntermediateDirectories: true)
        try "// engine v2".write(to: mjsDir.appendingPathComponent("x-usage-provider.mjs"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: hudDirOf(tmp), withIntermediateDirectories: true)
        DataEngine.installMjs(bundleDir: bundleDir, hudDir: hudDirOf(tmp))
        let dst = hudDirOf(tmp).appendingPathComponent("x-usage-provider.mjs")
        #expect(try String(contentsOf: dst, encoding: .utf8) == "// engine v2")

        try "// engine v3".write(to: mjsDir.appendingPathComponent("x-usage-provider.mjs"), atomically: true, encoding: .utf8)
        DataEngine.installMjs(bundleDir: bundleDir, hudDir: hudDirOf(tmp))
        #expect(try String(contentsOf: dst, encoding: .utf8) == "// engine v3")
        cleanup(tmp)
    }

    private func hudDirOf(_ tmp: URL) -> URL {
        tmp.appendingPathComponent("hud", isDirectory: true)
    }

    private func cleanup(_ tmp: URL) {
        try? FileManager.default.removeItem(at: tmp)
    }
    // MARK: P2-2/P2-3 凭证文件 0600 + 迁移字段级 merge

    @Test func instantiateAuthFileIs0600() throws {
        let tmp = makeTmp()
        let tmpl = try makeTemplate(slug: "testtype", in: tmp)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        _ = try PluginGenerator.instantiate(template: tmpl, slug: "tt-perm", name: "TT", into: userDir, hudDir: hudDir)
        let auth = hudDir.appendingPathComponent(".tt-perm-usage-auth.json")
        let perm = try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? Int
        #expect(perm == 0o600)
        cleanup(tmp)
    }

    @Test @MainActor func migrateMergesMissingFieldsOnly() throws {
        let tmp = makeTmp()
        _ = try makeTemplate(slug: "glm", in: tmp)
        let bundleDir = tmp.appendingPathComponent("bundle", isDirectory: true)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        // 首次迁移生成实例
        let defaults = UserDefaults(suiteName: "instance-tests-merge")!
        defaults.removePersistentDomain(forName: "instance-tests-merge")
        let runner = ProviderRunner(nodePath: "/usr/bin/true", logDir: hudDir)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: bundleDir,
                                userProvidersDir: userDir, runner: runner, defaults: defaults,
                                settingsURL: tmp.appendingPathComponent("settings.json"))
        engine.migrateAccounts()
        let manifestURL = userDir.appendingPathComponent("glm/manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // 手改实例 manifest (模拟用户/工具改动): refreshUrl 改值 + 删 testPrompt
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        obj["refreshUrl"] = "https://user-custom.example/v1/messages"
        obj.removeValue(forKey: "accent")  // 模板有此能力字段, 实例删掉 → 迁移应补回
        obj["displayName"] = "我的自定义名"
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)

        // 模板升级 (testPrompt 新增/改值) 后再迁移: 只补缺失字段, 手改不丢
        engine.migrateAccounts()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        #expect(after["refreshUrl"] as? String == "https://user-custom.example/v1/messages", "已有字段不得覆盖")
        #expect(after["displayName"] as? String == "我的自定义名", "用户字段不得覆盖")
        #expect(after["accent"] as? String == "blue", "缺失能力字段应按模板补齐")
        cleanup(tmp)
    }
}
