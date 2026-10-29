import Foundation
import Testing
@testable import TokenHUD

/// 一键导入: 三源解析 (临时目录 fixture, 不读真实配置)
@Suite
struct ImportTests {

    private func tmpHome() -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func sqlite(_ db: URL, _ sql: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    @Test func nineRouterGroupsByProvider() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbDir = home.appendingPathComponent(".9router/db")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = dbDir.appendingPathComponent("data.sqlite")
        sqlite(db, """
        create table providerConnections (id text, provider text, authType text, name text, isActive int, data text);
        insert into providerConnections values ('1','glm','apikey','acc','1','{"apiKey":"k1"}');
        insert into providerConnections values ('2','anthropic-compatible-x','apikey','relay','1','{"apiKey":"k2","providerSpecificData":{"baseUrl":"https://r.example"}}');
        insert into providerConnections values ('3','openai-compatible-chat-y','apikey','oai','1','{"apiKey":"k3","providerSpecificData":{"baseUrl":"https://o.example"}}');
        insert into providerConnections values ('4','glm','apikey','off','0','{"apiKey":"k4"}');
        """)
        let out = ProviderImporter.from9Router(home: home.path)
        #expect(out.count == 3)                       // 停用的不导
        #expect(out.contains { $0.template == "glm" })
        let relay = out.first { $0.name == "relay" }
        #expect(relay?.proto == "anthropic")
        #expect(relay?.baseURL == "https://r.example")
        #expect(out.first { $0.name == "oai" }?.proto == "openai")
    }

    @Test func ccSwitchClaudeEnv() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".cc-switch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("cc-switch.db")
        sqlite(db, """
        create table providers (id text, app_type text, name text, settings_config text);
        insert into providers values ('a','claude','Relay','{"env":{"ANTHROPIC_BASE_URL":"https://x.example","ANTHROPIC_AUTH_TOKEN":"sk-1234567890"}}');
        insert into providers values ('b','claude','Empty','{"env":{}}');
        insert into providers values ('c','codex','OA','{"auth":{}}');
        """)
        let out = ProviderImporter.fromCCSwitch(home: home.path)
        #expect(out.count == 1)                        // 缺 url/key 与 codex 型均跳过
        #expect(out[0].apiKey == "sk-1234567890")
        #expect(out[0].proto == "anthropic")
        #expect(out[0].note.contains("x.example"))
    }

    @Test func cpampOnlyImportsKeyedCredentials() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cline: [String: Any] = ["type": "clinepass", "api_key": "clp_1", "label": "me"]
        let codex: [String: Any] = ["type": "codex", "access_token": "t", "email": "a@b"]
        try? JSONSerialization.data(withJSONObject: cline).write(to: dir.appendingPathComponent("c.json"))
        try? JSONSerialization.data(withJSONObject: codex).write(to: dir.appendingPathComponent("x.json"))
        let out = ProviderImporter.fromCPAMP(home: home.path)
        #expect(out.count == 1)                        // OAuth 型凭证由模板直读, 不导入
        #expect(out[0].template == "cline")
        #expect(out[0].apiKey == "clp_1")
    }

    @Test func applyCreatesIndependentInstances() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let userDir = home.appendingPathComponent("providers")
        let hudDir = home.appendingPathComponent("hud")
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        // 真实 ~/.claude/hud 快照: 导入只写传入的 hudDir, 不得外溢
        let realHud = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/hud")
        func realNames() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: realHud.path)) ?? [])
        }
        let before = realNames()
        let c = ImportCandidate(source: "t", name: "Same Name", template: nil, apiKey: "k",
                                baseURL: "https://a.example", proto: "openai", note: "")
        let s1 = try? ProviderImporter.apply(c, templates: [], userDir: userDir, hudDir: hudDir)
        let s2 = try? ProviderImporter.apply(c, templates: [], userDir: userDir, hudDir: hudDir)
        #expect(s1 != nil && s2 != nil)
        #expect(s1 != s2)                              // slug 冲突自动加序号
        let manifest = userDir.appendingPathComponent(s1!).appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        let fetch = userDir.appendingPathComponent(s1!).appendingPathComponent("fetch.sh")
        #expect(FileManager.default.fileExists(atPath: fetch.path))
        // auth 落在传入 hudDir
        #expect(FileManager.default.fileExists(atPath: hudDir.appendingPathComponent(".\(s1!)-usage-auth.json").path))
        // 真实 hud 目录无新增 .same-name*
        let added = realNames().subtracting(before).filter { $0.hasPrefix(".same-name") }
        #expect(added.isEmpty, "导入外溢到真实 hud 目录: \(added)")
    }

    @Test func triggerURLJoinsOnce() {
        // 已含 /v1 不重复拼; anthropic 走 /messages
        #expect(ProviderImporter.triggerURLForTest("https://a.example", "openai") == "https://a.example/v1/chat/completions")
        #expect(ProviderImporter.triggerURLForTest("https://a.example/v1", "anthropic") == "https://a.example/v1/messages")
        #expect(ProviderImporter.triggerURLForTest("https://a.example/", "openai") == "https://a.example/v1/chat/completions")
    }

    @Test func authStyleInferredWhenManifestSilent() {
        let m = ProviderManifest(name: "X", label: "X", buckets: [:], queryAuth: "header")
        #expect(m.authStyle == "local")
        let n = ProviderManifest(name: "Y", label: "Y", buckets: [:], queryAuth: "bearer")
        #expect(n.authStyle == "apikey")
        let o = ProviderManifest(name: "Z", label: "Z", buckets: [:], authMode: "oauth")
        #expect(o.authStyle == "oauth")
    }
}
