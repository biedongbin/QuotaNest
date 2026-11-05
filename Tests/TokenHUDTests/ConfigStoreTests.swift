import Foundation
import Testing
@testable import QuotaNest

/// Account persistence keeps base authentication and removes obsolete query identities.
@Suite
struct ConfigStoreTests {
    private func writeAuth(_ json: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(".auth-\(UUID()).json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func obsoleteQueryIdentitiesNeverSupplyBaseAuthentication() throws {
        let file = try writeAuth(#"{"queryKey":"query-only","headers":{"authorization":"jwt-only","Cookie":"sid=1"},"cookieAuth":"sid=2","quotaCredentialMode":"legacy"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        var manifest = ProviderManifest(name: "fixture", label: "fixture")
        manifest.queryAuth = "jwt"
        manifest.refreshAuth = "cookie"
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        #expect(config.refreshKey.isEmpty && config.queryKey.isEmpty)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(config) }
    }

    @Test func oldSharedBaseAPIKeyLayoutsRemainReadable() throws {
        let headerFile = try writeAuth(#"{"headers":{"Authorization":"Bearer shared-key"}}"#)
        defer { try? FileManager.default.removeItem(at: headerFile) }
        var manifest = ProviderManifest(name: "fixture", label: "fixture")
        let defaultConfig = ProviderConfigStore.read(authFile: headerFile, manifest: manifest)
        #expect(defaultConfig.refreshKey == "shared-key")
        manifest.queryAuth = "bearer"
        #expect(ProviderConfigStore.read(authFile: headerFile, manifest: manifest).refreshKey == "shared-key")
        try ProviderConfigStore.write(defaultConfig, manifest: manifest, to: headerFile)
        #expect(ProviderConfigStore.read(authFile: headerFile, manifest: manifest).refreshKey == "shared-key")
        let keyedFile = try writeAuth(#"{"apiKey":"declared-key"}"#)
        defer { try? FileManager.default.removeItem(at: keyedFile) }
        manifest.queryKeyField = "apiKey"
        #expect(ProviderConfigStore.read(authFile: keyedFile, manifest: manifest).refreshKey == "declared-key")
    }

    @Test func explicitEmptyBaseKeyDoesNotRestoreAnOldIdentity() throws {
        let file = try writeAuth(#"{"schemaVersion":2,"refreshApiKey":"","queryKey":"old-query","apiKey":"old-shared","headers":{"Authorization":"Bearer old-header"}}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = ProviderManifest(name: "fixture", label: "fixture", queryAuth: "bearer", queryKeyField: "apiKey")
        #expect(ProviderConfigStore.read(authFile: file, manifest: manifest).refreshKey.isEmpty)
    }

    @Test func savingCleansQueryFieldsAndKeepsBaseAndUnknownFields() throws {
        let file = try writeAuth(#"{"refreshApiKey":"base-key","apiKey":"old-key","queryKey":"old-query","queryToken":"old-token","queryCookie":"old-cookie","cookieAuth":"sid=1","quotaCredentialMode":"legacy","headers":{"Authorization":"Bearer old","authorization":"jwt","COOKIE":"sid=2","x-trace":"keep"},"queryUrl":"https://quota.example.test/usage","quotaMode":"endpoint","scheduleTimes":["09:00"],"other":{"keep":true}}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = ProviderManifest(name: "fixture", label: "fixture", queryAuth: "bearer", queryKeyField: "apiKey")
        var config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        config.queryKey = "must-never-persist"
        try ProviderConfigStore.write(config, manifest: manifest, to: file)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["queryKey", "queryToken", "queryCookie", "cookieAuth", "quotaCredentialMode", "apiKey"] {
            #expect(saved[key] == nil)
        }
        #expect(saved["refreshApiKey"] as? String == "base-key")
        #expect(saved["authMode"] as? String == "apikey")
        #expect(saved["queryUrl"] as? String == "https://quota.example.test/usage")
        #expect(saved["quotaMode"] as? String == "endpoint")
        #expect(saved["scheduleTimes"] as? [String] == ["09:00"])
        #expect((saved["headers"] as? [String: String]) == ["x-trace": "keep"])
        #expect((saved["other"] as? [String: Bool]) == ["keep": true])
        let reread = ProviderConfigStore.read(authFile: file, manifest: manifest)
        #expect(try ProviderAuthentication.resolveQuota(reread).queryKey == "base-key")
    }

    @Test func readManifestQueryURLWinsAndScheduleSurvives() throws {
        let file = try writeAuth(#"{"apiUrl":"https://old.example.test","refreshApiKey":"base","scheduleTimes":["09:00","18:30"]}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = ProviderManifest(name: "fixture", label: "fixture", queryUrl: "https://new.example.test")
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        #expect(config.queryUrl == "https://new.example.test")
        #expect(config.scheduleTimes == ["09:00", "18:30"])
    }

    @Test func cleanupDetectionInvalidatesOnceAndProtectsDeclaredSourcePointers() throws {
        let file = try writeAuth(#"{"refreshApiKey":"base","token":"/fixture/auth.json","cookie":"","headers":{"Cookie":"old","x-trace":"keep"}}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = ProviderCredentialSource(file: "/fixture/auth.json", tokenPath: "tokens.access_token", fileConfigKey: "token")
        let manifest = ProviderManifest(name: "fixture", label: "fixture", credentialSource: source)
        #expect(ProviderConfigStore.hasObsoleteQueryCredentials(authFile: file, manifest: manifest))
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        try ProviderConfigStore.write(config, manifest: manifest, to: file)
        #expect(!ProviderConfigStore.hasObsoleteQueryCredentials(authFile: file, manifest: manifest))
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["token"] as? String == "/fixture/auth.json")
        #expect(saved["cookie"] == nil)
    }

    @Test func emptyScheduleRemovesKey() throws {
        let file = try writeAuth(#"{"scheduleTimes":["09:00"]}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        try ProviderConfigStore.write(ProviderConfig(), manifest: ProviderManifest(name: "fixture", label: "fixture"), to: file)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["scheduleTimes"] == nil)
    }
}

/// RefreshTrigger 纯函数层: header 解析与 <key> 占位替换
@Suite
struct RefreshTriggerTests {
    @Test func applyHeadersReplacesKeyPlaceholder() {
        var req = URLRequest(url: URL(string: "https://x.example.com")!)
        RefreshTrigger.applyHeaders(&req,
                                    "Authorization: Bearer <key>\nanthropic-version: 2023-06-01",
                                    key: "sk-abc", protocol: "anthropic")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abc")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func applyHeadersOpenAISkipsVersion() {
        var req = URLRequest(url: URL(string: "https://x.example.com")!)
        RefreshTrigger.applyHeaders(&req, "Authorization: Bearer <key>",
                                    key: "sk-abc", protocol: "openai")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abc")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == nil) // 非 anthropic 不加
    }

    @Test func applyHeadersIgnoresMalformedLines() {
        var req = URLRequest(url: URL(string: "https://x.example.com")!)
        RefreshTrigger.applyHeaders(&req, "garbage-no-colon\n: empty-key\nX-A: <key>",
                                    key: "k", protocol: "openai")
        #expect(req.value(forHTTPHeaderField: "X-A") == "k")
        #expect(req.allHTTPHeaderFields?.count == 1)
    }

    @Test func testRefreshGuards() async {
        // 空 url / 非法 url / 缺 model: 返回错误文案而非 crash (P0-1 回归)
        var c = ProviderConfig()
        c.refreshKey = "k"
        #expect(await RefreshTrigger.testRefresh(config: c) == "未配置刷新 url")
        c.refreshUrl = "https://[bad" // 非法 host (URL(string:) 必 nil)
        c.testModel = "m" // model 校验先于 url, 排除干扰
        #expect(await RefreshTrigger.testRefresh(config: c) == "刷新 url 非法")
        c.refreshUrl = "https://x.example.com/v1"
        c.testModel = ""
        #expect(await RefreshTrigger.testRefresh(config: c) == "未配置测试模型")
    }

    @Test func testQueryGuards() async {
        var c = ProviderConfig()
        #expect(await RefreshTrigger.testQuery(config: c) == "未配置查询 url")
        c.queryUrl = "https://[bad"
        c.queryKey = "k"
        #expect(await RefreshTrigger.testQuery(config: c) == "查询 url 非法")
    }

    // MARK: P1-5 调用结果不确定: 网络类错误 → "结果不确定，可能已消费"; 200 空 body → 响应异常

    @Test func networkErrorsClassifiedAsUncertain() {
        #expect(RefreshTrigger.isNetworkUncertain(URLError(.timedOut)))
        #expect(RefreshTrigger.isNetworkUncertain(URLError(.networkConnectionLost)))
        #expect(RefreshTrigger.isNetworkUncertain(URLError(.cannotConnectToHost)))
        #expect(RefreshTrigger.isNetworkUncertain(URLError(.dnsLookupFailed)))
        #expect(RefreshTrigger.isNetworkUncertain(URLError(.notConnectedToInternet)))
        // 非网络类 (请求确定未达业务端 / 本地取消) 不标不确定
        #expect(!RefreshTrigger.isNetworkUncertain(URLError(.cancelled)))
        #expect(!RefreshTrigger.isNetworkUncertain(URLError(.badURL)))
        #expect(!RefreshTrigger.isNetworkUncertain(NSError(domain: "x", code: 1)))
    }

    @Test func timeoutInjectedYieldsUncertainMessage() {
        // 注入超时错误 → describe 产出不确定文案 (SettingsModel.testCall 直接展示该串)
        let msg = RefreshTrigger.describe(error: URLError(.timedOut))
        #expect(msg.hasPrefix("结果不确定，可能已消费"))
        #expect(msg.contains("请求可能已送达"))
        // 非网络类照常展示 localizedDescription, 不加不确定前缀
        let plain = RefreshTrigger.describe(error: URLError(.cancelled))
        #expect(!plain.hasPrefix("结果不确定"))
        #expect(plain == URLError(.cancelled).localizedDescription)
    }

    @Test func emptyBodyIsNotSuccess() {
        // P1-5 成功判定 (SettingsModel.testCall 同一约定): "✓ " 前缀 = HTTP 200 且 body 非空
        #expect("✓ {\"id\":\"x\"}".hasPrefix("✓"))
        #expect(!RefreshTrigger.emptyBodyMessage.hasPrefix("✓"))
        #expect(!RefreshTrigger.describe(error: URLError(.timedOut)).hasPrefix("✓"))
    }

    @Test func scheduleTimeFormat() {
        // 与 SettingsValidation.isValidTime 一致: HH:MM 24h 制
        #expect(SettingsValidation.isValidTime("09:00"))
        #expect(SettingsValidation.isValidTime("23:59"))
        #expect(!SettingsValidation.isValidTime("9:00"))   // 非 2 位
        #expect(!SettingsValidation.isValidTime("24:00"))  // 时越界
        #expect(!SettingsValidation.isValidTime("09:60"))  // 分越界
        #expect(!SettingsValidation.isValidTime("abc"))
        #expect(!SettingsValidation.isValidTime(""))
    }

    @Test func settingsValidationRules() {
        // URL: 仅 http/https + 非空 host, 拒绝空白/控制字符/百分号 host
        #expect(SettingsValidation.isValidURL("https://api.example.com/v1"))
        #expect(SettingsValidation.isValidURL("http://127.0.0.1:8080"))
        #expect(!SettingsValidation.isValidURL("ftp://api.example.com"))
        #expect(!SettingsValidation.isValidURL("api.example.com"))
        #expect(!SettingsValidation.isValidURL("https://"))
        #expect(!SettingsValidation.isValidURL("https://exa mple.com"))
        #expect(!SettingsValidation.isValidURL("https://exa\tmple.com"))
        #expect(!SettingsValidation.isValidURL("https://exa%20mple.com"))

        // 配置: 仅结构错误拒绝 (P1-10); key/url 缺失转 isIncomplete 判定
        var e = SettingsValidation.configErrors(name: " ", key: "", url: "",
                                                authStyle: "apikey", builtin: false)
        #expect(e["name"] != nil && e["key"] == nil && e["url"] == nil)
        e = SettingsValidation.configErrors(name: "a", key: "k", url: "",
                                           authStyle: "apikey", builtin: true)
        #expect(e.isEmpty)
        e = SettingsValidation.configErrors(name: "a", key: "", url: "",
                                           authStyle: "local", builtin: false)
        #expect(e.isEmpty)  // 本机凭证型不要求 key/url

        // 定时: 格式 / 重复 / 开启需至少一个
        #expect(SettingsValidation.triggerErrors(times: [], timeInput: "9:00",
                                                 triggerEnabled: false, canCall: true)["time"] != nil)
        #expect(SettingsValidation.triggerErrors(times: ["09:00"], timeInput: "09:00",
                                                 triggerEnabled: false, canCall: true)["time"] != nil)
        #expect(SettingsValidation.triggerErrors(times: [], timeInput: "",
                                                 triggerEnabled: true, canCall: true)["times"] != nil)
        #expect(SettingsValidation.triggerErrors(times: ["09:00"], timeInput: "",
                                                 triggerEnabled: true, canCall: true).isEmpty)
        #expect(SettingsValidation.triggerErrors(times: [], timeInput: "9:00",
                                                 triggerEnabled: true, canCall: false).isEmpty)
    }

    // MARK: P1-8 错误四态: 判定集中 CapabilityStatus, 纯函数

    @Test func capabilityFourStates() {
        // 额度查询: 有 queryUrl/cacheFile = 已支持; 通用自定义无 = 未接入 (App 侧)
        let withUrl = ProviderManifest(name: "A", label: "a", queryUrl: "https://q.example")
        #expect(CapabilityStatus.quota(manifest: withUrl) == .configured)
        let withCache = ProviderManifest(name: "B", label: "b", cacheFile: "~/.claude/hud/.b-cache.json")
        #expect(CapabilityStatus.quota(manifest: withCache) == .configured)
        let generic = ProviderManifest(name: "C", label: "c")   // 通用: 无 queryUrl/cacheFile
        #expect(CapabilityStatus.quota(manifest: generic) == .notIntegrated)
        // 模型调用: refreshUrl 有 = 已支持; 模板实例无 = App 未接入;
        // 通用未填地址 = 未配置 (可补), 填了 = 已支持
        let callable = ProviderManifest(name: "D", label: "d", refreshUrl: "https://r.example/v1/messages")
        #expect(CapabilityStatus.call(manifest: callable, configUrl: "") == .configured)
        let tmplNoCall = ProviderManifest(name: "E", label: "e", template: "gpt")
        #expect(CapabilityStatus.call(manifest: tmplNoCall, configUrl: "") == .notIntegrated)
        #expect(CapabilityStatus.call(manifest: generic, configUrl: "") == .notConfigured)
        #expect(CapabilityStatus.call(manifest: generic, configUrl: "https://api.example.com") == .configured)
        // 标签齐备 (文案统一来源)
        #expect(CapabilityStatus.notConfigured.label == "未配置")
        #expect(CapabilityStatus.notIntegrated.label == "未接入")
        #expect(CapabilityStatus.notSupported.label == "不支持")
        #expect(CapabilityStatus.unverified.label == "待核实")
        #expect(CapabilityStatus.configured.label == "已支持")
    }

    // MARK: P1-10 合法不完整可保存: 仅结构错误拒绝; 执行性缺失 → 未配置 + 依赖开关强制 off

    @Test func incompletePredicate() {
        // 结构错误仍拒绝 (仅名称)
        #expect(SettingsValidation.configErrors(name: " ", key: "k", url: "https://a.example",
                                                authStyle: "apikey", builtin: false)["name"] != nil)
        // 执行性缺失: 不进 errors, 但 isIncomplete=true
        #expect(SettingsValidation.configErrors(name: "a", key: "", url: "",
                                                authStyle: "apikey", builtin: false).isEmpty)
        #expect(SettingsValidation.isIncomplete(name: "a", key: "", url: "",
                                                authStyle: "apikey", builtin: false))          // 缺 key
        #expect(SettingsValidation.isIncomplete(name: "a", key: "k", url: "",
                                                authStyle: "apikey", builtin: false))          // 缺 url
        #expect(SettingsValidation.isIncomplete(name: "a", key: "k", url: "notaurl",
                                                authStyle: "apikey", builtin: false))          // url 非法
        #expect(!SettingsValidation.isIncomplete(name: "a", key: "k", url: "https://a.example",
                                                 authStyle: "apikey", builtin: false))         // 齐
        #expect(!SettingsValidation.isIncomplete(name: "a", key: "", url: "",
                                                 authStyle: "apikey", builtin: true,
                                                 hasExistingKey: true))                        // 空=保持原值
        #expect(!SettingsValidation.isIncomplete(name: "a", key: "", url: "",
                                                 authStyle: "local", builtin: false))          // 本机凭证不缺
    }

    @Test @MainActor func incompleteSavePausesCallsWithoutDisablingAccount() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-inc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let userDir = tmp.appendingPathComponent("providers", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: nil, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: nil, logDir: hudDir),
                                defaults: UserDefaults(suiteName: "th-inc-\(UUID().uuidString)")!,
                                settingsURL: tmp.appendingPathComponent("settings.json"))
        let model = SettingsModel(engine: engine, hudDir: hudDir, userDir: userDir,
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: UserDefaults(suiteName: "th-model-\(UUID().uuidString)")!)
        // 缺调用凭证可以保存为未配置账号，不应连带停用账号。
        var v = DraftValues()
        v.name = "半配置号"
        v.url = "https://api.example.com"
        v.key = ""            // 执行性缺失
        v.autoQuery = true    // 账号启用与调用是否就绪独立
        model.draft = Draft(slug: nil, template: nil, isNew: true, values: v, base: DraftValues())
        model.save()
        #expect(model.topError.isEmpty)                 // 结构无错 → 保存放行
        #expect(engine.allPlugins.contains { $0.slug == "ban-zhi-hao" || $0.manifest.fullName.contains("半配置") })
        #expect(!engine.disabledSlugs.contains(engine.allPlugins[0].slug)) // 保留账号启用意图
        #expect(engine.triggerDisabledSlugs.contains(engine.allPlugins[0].slug))
        let row = model.accounts.first
        #expect(row?.isConfigured == false)             // 状态 = 未配置
    }

    @Test func emptyKeyKeepsExistingOnValidation() {
        // P1-10: key 缺失不再进 errors (可保存); 区分走 isIncomplete —
        // 已有盘上 Key + 空输入 = 保持原值 → 完整; 无盘上 Key → 未配置
        let e = SettingsValidation.configErrors(name: "a", key: "", url: "",
                                                authStyle: "apikey", builtin: true,
                                                hasExistingKey: true)
        #expect(e.isEmpty)
        #expect(!SettingsValidation.isIncomplete(name: "a", key: "", url: "",
                                                 authStyle: "apikey", builtin: true,
                                                 hasExistingKey: true))
        let n = SettingsValidation.configErrors(name: "a", key: "", url: "",
                                                authStyle: "apikey", builtin: true,
                                                hasExistingKey: false)
        #expect(n.isEmpty)  // 可保存
        #expect(SettingsValidation.isIncomplete(name: "a", key: "", url: "",
                                                authStyle: "apikey", builtin: true,
                                                hasExistingKey: false))  // 但标未配置
    }

    @Test func keyIntentResolveThreeWays() {
        // replace + 空 + 盘上有值 → nil (不动盘上)
        #expect(SettingsValidation.resolveKey(draftKey: "", existingKey: "old",
                                              intent: .replace) == nil)
        // replace + 新值 → 替换
        #expect(SettingsValidation.resolveKey(draftKey: "new", existingKey: "old",
                                              intent: .replace) == "new")
        // replace + 空 + 盘上也空 → 写空 (新建场景, 与校验互斥仅防御)
        #expect(SettingsValidation.resolveKey(draftKey: "", existingKey: "",
                                              intent: .replace) == "")
        // clear → 清空 (即使草稿框里有值)
        #expect(SettingsValidation.resolveKey(draftKey: "new", existingKey: "old",
                                              intent: .clear) == "")
        #expect(SettingsValidation.resolveKey(draftKey: "", existingKey: "old",
                                              intent: .clear) == "")
    }

    @Test @MainActor func updateKeyThreeIntentsPersist() throws {
        // 端到端: 三种 intent 经 update() 落盘行为 (key 空输入=保持 / clear=清空 / 新值=替换)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let userDir = tmp.appendingPathComponent("providers", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: nil, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: nil, logDir: hudDir),
                                defaults: UserDefaults(suiteName: "th-key-\(UUID().uuidString)")!,
                                settingsURL: tmp.appendingPathComponent("settings.json"))
        let authFile = hudDir.appendingPathComponent(".kacct-usage-auth.json")
        try JSONSerialization.data(withJSONObject: ["refreshApiKey": "old-key", "headers": [:]])
            .write(to: authFile)
        let d = userDir.appendingPathComponent("kacct", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProviderManifest(name: "kacct", label: "kacct", buckets: [:],
                                                  authFile: authFile.path))
            .write(to: d.appendingPathComponent("manifest.json"))
        try? "#!/bin/zsh\necho '{}'".write(to: d.appendingPathComponent("fetch.sh"),
                                           atomically: true, encoding: .utf8)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hudDir, userDir: userDir,
                                  settingsURL: tmp.appendingPathComponent("settings.json"), bundleDir: nil,
                                  defaults: UserDefaults(suiteName: "th-model-\(UUID().uuidString)")!)
        model.selected = "kacct"

        func runUpdate(key: String, clear: Bool) -> String {
            model.startEdit()
            model.draft?.values.url = "https://api.example.com"   // url 校验先行, 不设则保存被挡
            model.draft?.values.key = key
            model.draft?.values.clearKeyIntent = clear
            model.save()
            #expect(model.topError.isEmpty)
            return ProviderConfigStore.read(authFile: authFile,
                manifest: engine.allPlugins.first { $0.slug == "kacct" }!.manifest).refreshKey
        }
        #expect(runUpdate(key: "", clear: false) == "old-key")   // 空 = 保持原值
        #expect(runUpdate(key: "", clear: true) == "")           // clear = 清空
        #expect(runUpdate(key: "fresh", clear: false) == "fresh") // 新值 = 替换
    }

}

@Suite
struct ConfigP2Tests {
    private let tmp = FileManager.default.temporaryDirectory

    private func writeAuth(_ json: String) throws -> URL {
        let u = tmp.appendingPathComponent(".auth-\(UUID().uuidString).json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func readBack(_ u: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any] ?? [:]
    }

    // MARK: P2-2/P2-3/P2-6 凭证文件 0600 + schemaVersion + 默认调用参数

    @Test func writeSetsAuthFilePermissions0600() throws {
        let f = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"refreshApiKey":"rk"}"#)
        var m = ProviderManifest(name: "R", label: "R")
        m.queryAuth = "bearer"; m.refreshAuth = "bearer"
        var c = ProviderConfigStore.read(authFile: f, manifest: m)
        c.queryKey = "k2"; c.refreshKey = "k2"
        try ProviderConfigStore.write(c, manifest: m, to: f)
        let perm = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int
        #expect(perm == 0o600)
    }

    @Test func writeStampsSchemaVersion() throws {
        let f = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"refreshApiKey":"rk"}"#)
        var m = ProviderManifest(name: "R", label: "R")
        m.queryAuth = "bearer"; m.refreshAuth = "bearer"
        var c = ProviderConfigStore.read(authFile: f, manifest: m)
        c.queryKey = "k"; c.refreshKey = "k"
        try ProviderConfigStore.write(c, manifest: m, to: f)
        let obj = try readBack(f)
        #expect(obj["schemaVersion"] as? Int == 3)
    }

    @Test func defaultTestPromptAndMaxTokens() throws {
        // 旧 auth 无 testPrompt/testMaxTokens → 新默认 ("只回复OK"/16)
        let f = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"refreshApiKey":"rk"}"#)
        var m = ProviderManifest(name: "R", label: "R")
        m.queryAuth = "bearer"; m.refreshAuth = "bearer"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.testPrompt == "只回复OK")
        #expect(c.testMaxTokens == 16)
        // 已有值优先
        let f2 = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"refreshApiKey":"rk","testPrompt":"hi","testMaxTokens":8}"#)
        let c2 = ProviderConfigStore.read(authFile: f2, manifest: m)
        #expect(c2.testPrompt == "hi")
        #expect(c2.testMaxTokens == 8)
    }
}
