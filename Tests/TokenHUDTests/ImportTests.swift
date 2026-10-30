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
        // 全量列出: 停用的照样出现, 只是标记 enabled=false (源侧开关, 不等于不可导)
        #expect(out.count == 4)
        #expect(out.contains { $0.template == "glm" && $0.enabled })
        #expect(out.contains { $0.name == "GLM · off" && !$0.enabled })
        let relay = out.first { $0.name == "Anthropic 兼容 · relay" }
        #expect(relay?.proto == "anthropic")
        #expect(relay?.baseURL == "https://r.example")
        #expect(out.first { $0.name == "OpenAI 兼容 · oai" }?.proto == "openai")
    }

    @Test func nineRouterMasksSourceAccountIds() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbDir = home.appendingPathComponent(".9router/db")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = dbDir.appendingPathComponent("data.sqlite")
        sqlite(db, """
        create table providerConnections (id text, provider text, authType text, name text, isActive int, data text);
        insert into providerConnections values ('1','cline','oauth','jackli0098255@gmail.com','1','{"accessToken":"t"}');
        insert into providerConnections values ('2','codex','oauth','biedongbin@gmail.com','1','{"accessToken":"t"}');
        insert into providerConnections values ('3','codex','oauth','jkokkjh578532467889@gmail.com','0','{"accessToken":"t"}');
        """)
        let out = ProviderImporter.from9Router(home: home.path)
        #expect(out.count == 3)
        // 预览名不含完整邮箱, 落盘 slug 也不含
        for c in out {
            #expect(!c.name.contains("@"))
            #expect(!(c.slugHint ?? c.name).contains("@"))
        }
        #expect(out.map(\.name) == ["Cline 账号 1", "Codex 账号 1", "Codex 账号 2"])
        #expect(out[0].sourceAccount == "ja***@g***.com")   // 原邮箱脱敏后仅出现在说明行
    }

    @Test func nineRouterKeepsUnmappableRowsVisible() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbDir = home.appendingPathComponent(".9router/db")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = dbDir.appendingPathComponent("data.sqlite")
        sqlite(db, """
        create table providerConnections (id text, provider text, authType text, name text, isActive int, data text);
        insert into providerConnections values ('1','codex','oauth','a@b','0','{"accessToken":"t"}');
        insert into providerConnections values ('2','openai-compatible-chat-z','apikey','no-url','0','{"apiKey":"k"}');
        insert into providerConnections values ('3','glm','apikey','nokey','1','{}');
        """)
        let out = ProviderImporter.from9Router(home: home.path)
        #expect(out.count == 3)                        // 不可映射的也列出, 不静默丢弃
        let oauth = out.first { $0.note.contains("codex") }
        #expect(oauth?.unsupportedReason != nil)
        #expect(oauth?.enabled == false)
        #expect(out.contains { $0.name.contains("no-url") && $0.unsupportedReason?.contains("接口地址") == true })
        #expect(out.contains { $0.note.hasPrefix("glm /") && $0.unsupportedReason != nil })
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

    // MARK: P1-7 导入事务化: 失败零残留 / 取消保留成功项

    @Test func applyFailureLeavesNoResidue() throws {
        let (userDir, hudDir) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: userDir.deletingLastPathComponent()) }
        // 冲突注入: 目标 auth 文件已预置 (uniqueSlug 只查插件目录 → slug 相同 → 阶段二冲突)
        try? Data("{}".utf8).write(to: hudDir.appendingPathComponent(".clash-usage-auth.json"))
        let c = ImportCandidate(source: "t", name: "Clash", template: nil, apiKey: "k",
                                baseURL: "https://a.example", proto: "openai", note: "")
        #expect(throws: (any Error).self) {
            _ = try ProviderImporter.apply(c, templates: [], userDir: userDir, hudDir: hudDir)
        }
        // 目标零污染: 无插件目录, 无 staging 残留
        #expect(!FileManager.default.fileExists(atPath: userDir.appendingPathComponent("clash").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: userDir.path)) ?? []
        #expect(leftovers.filter { $0.hasPrefix(".tokenhud-import-") }.isEmpty,
                "staging 目录残留: \(leftovers)")
        // 预置 auth 未被覆盖 (事务不破坏既有文件)
        let pre = try String(contentsOf: hudDir.appendingPathComponent(".clash-usage-auth.json"), encoding: .utf8)
        #expect(pre == "{}")
    }

    @Test @MainActor func importCancelSkipsUnstartedItems() async throws {
        // 取消语义: 已开始 Task 未跑即取消 → 全部标 skipped, 目标零落盘; 重试后正常导入
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-cancel-\(UUID().uuidString)")
        let userDir = home.appendingPathComponent("providers", isDirectory: true)
        let hudDir = home.appendingPathComponent("hud", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "th-cancel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: nil, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: nil), defaults: defaults)
        let im = ImportCenterModel(engine: engine, hudDir: hudDir, userDir: userDir)
        let c1 = ImportCandidate(source: "t", name: "Keep Me", template: nil, apiKey: "k",
                                 baseURL: "https://a.example", proto: "openai", note: "")
        let c2 = ImportCandidate(source: "t", name: "Skip Me", template: nil, apiKey: "k",
                                 baseURL: "https://b.example", proto: "openai", note: "")
        im.rows = [ImportCenterModel.Row(candidate: c1, state: .unadapted, note: ""),
                   ImportCenterModel.Row(candidate: c2, state: .unadapted, note: "")]
        im.picked = Set(im.rows.map(\.id))
        im.importSelected()
        im.cancelImport()   // 同步取消: Task 体未跑 → 首个循环迭代即见 isCancelled
        // 等导入 Task 结束 (全部 skipped)
        while im.importing { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(im.rows.allSatisfy { !$0.imported })       // 未开始项不落盘
        #expect(!FileManager.default.fileExists(atPath:
            userDir.appendingPathComponent("keep-me").path))
        #expect(!FileManager.default.fileExists(atPath:
            userDir.appendingPathComponent("skip-me").path))
        #expect(im.lastMessage.contains("已取消"))          // 取消有可见反馈
        // 重试 (不取消): 正常完成 — 取消不破坏后续导入
        im.importSelected()
        while im.importing { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(im.rows.allSatisfy { $0.imported })
        #expect(FileManager.default.fileExists(atPath:
            userDir.appendingPathComponent("keep-me").path))
    }

    @Test func authStyleInferredWhenManifestSilent() {
        let m = ProviderManifest(name: "X", label: "X", buckets: [:], queryAuth: "header")
        #expect(m.authStyle == "local")
        let n = ProviderManifest(name: "Y", label: "Y", buckets: [:], queryAuth: "bearer")
        #expect(n.authStyle == "apikey")
        let o = ProviderManifest(name: "Z", label: "Z", buckets: [:], authMode: "oauth")
        #expect(o.authStyle == "oauth")
    }

    // MARK: P0-4 导入去重按 origin (source+recordId), 同名不算重复

    private func tmpDirs() -> (URL, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-origin-\(UUID().uuidString)")
        let userDir = home.appendingPathComponent("providers", isDirectory: true)
        let hudDir = home.appendingPathComponent("hud", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        return (userDir, hudDir)
    }

    @Test func applyStampsOriginIntoManifest() throws {
        let (userDir, hudDir) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: userDir.deletingLastPathComponent()) }
        let c = ImportCandidate(source: "9router", name: "Relay", template: nil, apiKey: "k",
                                baseURL: "https://a.example", proto: "openai", note: "",
                                sourceRecordId: "conn-7")
        let slug = try ProviderImporter.apply(c, templates: [], userDir: userDir, hudDir: hudDir)
        let data = try Data(contentsOf: userDir.appendingPathComponent(slug + "/manifest.json"))
        let m = try JSONDecoder().decode(ProviderManifest.self, from: data)
        #expect(m.origin == "9router:conn-7")
        // 解码容错: 旧 manifest 无 origin 字段照常读
        let legacy = #"{"name":"L","label":"l","fetch":"./fetch.sh","buckets":{}}"#
        let lm = try JSONDecoder().decode(ProviderManifest.self, from: Data(legacy.utf8))
        #expect(lm.origin == nil)
    }

    @Test func stateOfMatchesOriginNotDisplayName() {
        // 已存在账号: 手建 (origin nil), 同名
        let manifest = ProviderManifest(name: "Relay", label: "Relay", displayName: "Relay",
                                        buckets: [:], origin: nil)
        let existing = [PluginProvider(slug: "relay", manifest: manifest,
                                       dir: URL(fileURLWithPath: "/tmp"))]
        let lookup: (String) -> ProviderManifest? = { _ in
            ProviderManifest(name: "T", label: "t", buckets: [:], queryUrl: "https://q.example")
        }
        // 同名不同 recordId → 可新增 (FR-07.5 同名不算重复)
        let sameName = ImportCandidate(source: "9router", name: "Relay", template: nil, apiKey: "k",
                                       baseURL: "https://a.example", proto: "openai", note: "",
                                       sourceRecordId: "conn-1")
        #expect(ImportCenterModel.stateOf(sameName, existing: existing, templateLookup: lookup) == .unadapted)

        // 同源同 recordId → 已存在 (默认 skip)
        let again = ImportCandidate(source: "9router", name: "改名了也认得", template: nil, apiKey: "k2",
                                    baseURL: "https://a.example", proto: "openai", note: "",
                                    sourceRecordId: "conn-1")
        var withOrigin = existing
        withOrigin[0] = PluginProvider(slug: "relay",
                                       manifest: ProviderManifest(name: "Relay", label: "Relay",
                                                                  displayName: "Relay", buckets: [:],
                                                                  origin: "9router:conn-1"),
                                       dir: URL(fileURLWithPath: "/tmp"))
        #expect(ImportCenterModel.stateOf(again, existing: withOrigin, templateLookup: lookup) == .exists)

        // 无 recordId 的候选 (源没给) → 不判重, 走正常分类
        let noRec = ImportCandidate(source: "t", name: "Relay", template: nil, apiKey: "k",
                                    baseURL: "https://a.example", proto: "openai", note: "",
                                    sourceRecordId: "")
        #expect(ImportCenterModel.stateOf(noRec, existing: withOrigin, templateLookup: lookup) == .unadapted)
    }
}
