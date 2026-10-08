import Foundation
import Testing
@testable import TokenHUD

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
        let s = PluginGenerator.oneAPIFetchScript(slug: "my-relay")
        #expect(s.contains(".my-relay-usage-auth.json")) // url/key 运行时读 auth, 不内嵌
        #expect(!s.contains("sk-"))
        #expect(s.contains("billing/subscription"))
        #expect(s.contains("billing/usage"))
        // 传输层: SUB/USAGE 必须以真换行交给 python3（print -r 下 \n 是字面两字节，python 按真换行 split 必败）
        #expect(s.contains(#"printf '%s\n%s\n' "$SUB" "$USAGE""#))
    }

    @Test func scriptMergePipelineEndToEnd() throws {
        // 端到端: PATH 前置 stub curl + 写 auth 文件, 真实运行生成脚本验证读取管线
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pg-home-\(UUID())")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-e2e-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: home)
        }
        // 脚本读 $HOME/.claude/hud/.my-relay-usage-auth.json
        let hud = home.appendingPathComponent(".claude/hud", isDirectory: true)
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try """
        {"apiUrl": "https://x", "headers": {"Authorization": "Bearer sk-k"}, "refreshApiKey": "sk-k"}
        """.write(to: hud.appendingPathComponent(".my-relay-usage-auth.json"), atomically: true, encoding: .utf8)

        let s = PluginGenerator.oneAPIFetchScript(slug: "my-relay")
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let curl = bin.appendingPathComponent("curl")
        try """
        #!/bin/zsh
        case "$*" in
          *subscription*) print -r -- '{"hard_quota": 100}' ;;
          *usage*) print -r -- '{"total_usage": 25}' ;;
        esac
        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let script = dir.appendingPathComponent("fetch.sh")
        try s.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0)
        #expect(txt.contains("\"seven_day\""))
        #expect(txt.contains("25.0"))
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
