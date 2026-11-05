import Foundation
import Testing
@testable import QuotaNest

/// GeneratorTests: slug 化与 one-api 插件生成 (auth 文件读取版 fetch.sh)
@Suite
struct GeneratorTests {
    // ponytail: brief 期望 "openai-" 与"非法字符逐个→'-'、连续非法→连续'-'、不 trim"语义矛盾
    // （中转! 共 3 个非法字符 + 下划线 1 个 → "openai----"），按任务指令以语义为准修断言
    @Test func slugify() {
        #expect(PluginGenerator.slugify("My Relay") == "my-relay")
        #expect(PluginGenerator.slugify("OpenAI_中转!") == "openai----")
        #expect(PluginGenerator.slugify("") == "custom")
        #expect(PluginGenerator.slugify("A--B") == "a--b")
        #expect(PluginGenerator.slugify("GLM") == "glm") // 大写即冲突源: 新建时须检测
    }

    @Test func fetchScriptReadsAuthFile() {
        let script = PluginGenerator.oneAPIFetchScript(slug: "my-relay")
        #expect(script.contains(".my-relay-usage-auth.json"))
        #expect(script.contains("TOKENHUD_AUTH_FILE"))
        #expect(script.contains("generic-usage-provider.mjs"))
        #expect(!script.contains("billing/"))
        #expect(!script.contains("sk-"))
    }

    @Test func scriptMergePipelineEndToEnd() throws {
        // 真实执行生成的 shell + Node adapter，HTTP 传输由离线 curl 替身提供。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pg-endpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hud = root.appendingPathComponent("independent-config")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TokenHUD/mjs")
        for name in ["generic-usage-provider.mjs", "usage-normalize.mjs"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: hud.appendingPathComponent(name))
        }
        let auth = hud.appendingPathComponent(".my-relay-usage-auth.json")
        try Data(#"{"tokenhudResolvedAuth":true,"quotaMode":"endpoint","queryUrl":"https://quota.example.test/exact","queryKey":"fixture-quota","headers":{"Authorization":"Bearer fixture-quota"},"refreshApiKey":"must-not-be-used"}"#.utf8).write(to: auth)
        let curl = root.appendingPathComponent("curl")
        try """
        #!/bin/zsh
        print -r -- "$@" > "$TOKENHUD_TEST_ARGUMENTS"
        print -r -- '{"weekly":{"used_percentage":25}}'
        printf '200'
        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let script = root.appendingPathComponent("fetch.sh")
        try PluginGenerator.oneAPIFetchScript(slug: "my-relay").write(to: script, atomically: true, encoding: .utf8)
        let node = try #require(NodeLocator.find(nvmHome: NSHomeDirectory() + "/.nvm",
            extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"], saved: nil))
        let args = root.appendingPathComponent("arguments.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["TOKENHUD_NODE"] = node
        env["TOKENHUD_HUD_DIR"] = hud.path
        env["TOKENHUD_CURL"] = curl.path
        env["TOKENHUD_TEST_ARGUMENTS"] = args.path
        process.environment = env
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        let cache = try JSONDecoder().decode(UsageCache.self, from: data)
        #expect(cache.error == nil, "离线额度结果：\(String(decoding: data, as: UTF8.self))")
        #expect(cache.sevenDay?.usedPercentage == 25)
        #expect(cache.sevenDay?.resetsAt == nil)
        let arguments = try String(contentsOf: args, encoding: .utf8)
        #expect(arguments.contains("https://quota.example.test/exact"))
        #expect(arguments.contains("fixture-quota"))
        #expect(!arguments.contains("must-not-be-used"))
        #expect(!arguments.contains("billing"))
    }

    @Test func scriptSyntaxValid() throws {
        let s = PluginGenerator.oneAPIFetchScript(slug: "x")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID()).sh")
        try s.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-n", tmp.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func writeAndRemovePlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = PluginGenerator.customManifest(
            name: "Relay", config: ProviderConfig(), authFile: "~/.claude/hud/.my-relay-usage-auth.json")
        try PluginGenerator.writePlugin(slug: "my-relay", manifest: m,
            script: "#!/bin/zsh\ntrue", into: root)
        let dir = root.appendingPathComponent("my-relay")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fetch.sh").path))
        let perms = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("fetch.sh").path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        try PluginGenerator.removePlugin(slug: "my-relay", in: root)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func customManifestCarriesProtocolFields() {
        var c = ProviderConfig()
        c.queryUrl = "https://r.example.com"
        c.refreshUrl = "https://r.example.com/v1/chat/completions"
        c.refreshProtocol = "openai"
        c.refreshHeader = "Authorization: Bearer <key>"
        c.testModel = "gpt-x"
        let m = PluginGenerator.customManifest(name: "Relay", config: c, authFile: "~/.x.json")
        #expect(m.queryUrl == "https://r.example.com")
        #expect(m.refreshProtocol == "openai")
        #expect(m.testModel == "gpt-x")
        #expect(m.isBuiltin == false)
        #expect(m.refreshModel == "gpt-x") // refreshModel 即 testModel 回退源
    }
}
