import Foundation
import Testing
@testable import TokenHUD

@Suite
struct GeneratorTests {
    // ponytail: brief 期望 "openai-" 与"非法字符逐个→'-'、连续非法→连续'-'、不 trim"语义矛盾
    // （中转! 共 3 个非法字符 + 下划线 1 个 → "openai----"），按任务指令以语义为准修断言
    @Test func slugify() {
        #expect(PluginGenerator.slugify("My Relay") == "my-relay")
        #expect(PluginGenerator.slugify("OpenAI_中转!") == "openai----")
        #expect(PluginGenerator.slugify("") == "custom")
        #expect(PluginGenerator.slugify("A--B") == "a--b")
    }

    @Test func fetchScriptEmbedsParamsAndOutputsPct() {
        let s = PluginGenerator.oneAPIFetchScript(baseURL: "https://r.example.com", apiKey: "sk-abc")
        #expect(s.contains("https://r.example.com"))
        #expect(s.contains("sk-abc"))
        #expect(s.contains("billing/subscription"))
        #expect(s.contains("billing/usage"))
        #expect(s.contains("python3"))
        // 传输层: SUB/USAGE 必须以真换行交给 python3（print -r 下 \n 是字面两字节，python 按真换行 split 必败）
        #expect(s.contains(#"printf '%s\n%s\n' "$SUB" "$USAGE""#))
        #expect(!s.contains("print -r"))
    }

    @Test func scriptMergePipelineEndToEnd() throws {
        // 端到端: PATH 前置 stub curl，真实运行生成脚本，验证 curl→printf→python3 合并管线
        let s = PluginGenerator.oneAPIFetchScript(baseURL: "https://x", apiKey: "k")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
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
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0)
        #expect(txt.contains("\"seven_day\""))
        #expect(txt.contains("25.0"))
    }

    @Test func scriptActuallyRuns() throws {
        // 端到端需网络；此处验证脚本语法可执行: zsh -n 语法检查
        let s = PluginGenerator.oneAPIFetchScript(baseURL: "https://x", apiKey: "k")
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
        let m = PluginGenerator.oneAPIManifest(label: "Relay", intervalSec: 60)
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
}
