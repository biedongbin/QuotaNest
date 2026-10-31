import Foundation
import Testing
@testable import TokenHUD

/// ProviderConfigStore 读写往返: jwt/cookie/bearer 三形态 + refreshApiKey 回退 (P1-1 类分叉 bug 的防线)
@Suite
struct ConfigStoreTests {
    private let tmp = FileManager.default.temporaryDirectory

    private func writeAuth(_ json: String, name: String = UUID().uuidString) throws -> URL {
        let u = tmp.appendingPathComponent(".auth-\(name).json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func readBack(_ u: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any] ?? [:]
    }

    // MARK: read — 按 manifest.queryAuth 取凭证

    @Test func readJWT() throws {
        let f = try writeAuth(#"{"apiUrl":"https://glm.example.com","headers":{"authorization":"jwt-abc"},"refreshApiKey":"rk"}"#)
        var m = ProviderManifest(name: "CC-GLM", label: "GLM")
        m.queryAuth = "jwt"
        m.refreshAuth = "bearer"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.queryUrl == "https://glm.example.com") // 无 manifest.queryUrl 时回退 auth.apiUrl
        #expect(c.queryToken == "jwt-abc")
        #expect(c.refreshKey == "rk")
    }

    @Test func readCookie() throws {
        let f = try writeAuth(#"{"url":"https://oc.example.com","cookieAuth":"sid=1","refreshApiKey":"rk"}"#)
        var m = ProviderManifest(name: "OC-Go", label: "OC")
        m.queryAuth = "cookie"
        m.refreshAuth = "cookie"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.queryCookie == "sid=1")
        #expect(c.refreshKey == "sid=1") // refreshAuth=cookie 用同一 cookie
    }

    @Test func readBearerFallsBackToHeader() throws {
        // ollama 形态: 无 refreshApiKey, 回退 headers.Authorization (Bearer 前缀剥离)
        let f = try writeAuth(#"{"apiUrl":"https://o.example.com","headers":{"Authorization":"Bearer sk-x"}}"#)
        var m = ProviderManifest(name: "Ollama", label: "Ol")
        m.queryAuth = "bearer"
        m.refreshAuth = "bearer"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.queryKey == "sk-x")
        #expect(c.refreshKey == "sk-x") // 回退成功且无 Bearer 前缀
    }

    @Test func readManifestQueryUrlWins() throws {
        // 自定义供应商: manifest.queryUrl 优先于 auth.apiUrl
        let f = try writeAuth(#"{"apiUrl":"https://old.example.com","headers":{"Authorization":"Bearer k"}}"#)
        var m = ProviderManifest(name: "Relay", label: "Relay")
        m.queryAuth = "bearer"
        m.queryUrl = "https://new.example.com"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.queryUrl == "https://new.example.com")
    }

    @Test func readScheduleTimes() throws {
        let f = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"scheduleTimes":["09:00","18:30"]}"#)
        let c = ProviderConfigStore.read(authFile: f, manifest: ProviderManifest(name: "R", label: "R"))
        #expect(c.scheduleTimes == ["09:00", "18:30"])
    }

    // MARK: write — 往返保持

    @Test func writeRoundTripBearer() throws {
        let f = try writeAuth(#"{"apiUrl":"https://r.example.com","headers":{"Authorization":"Bearer old"}}"#)
        var m = ProviderManifest(name: "Relay", label: "Relay")
        m.queryAuth = "bearer"
        m.refreshAuth = "bearer"
        var c = ProviderConfig()
        c.queryKey = "sk-new"
        c.refreshKey = "rk-new"
        c.testModel = "m-1"
        c.testPrompt = "hi"
        c.scheduleTimes = ["09:00"]
        try ProviderConfigStore.write(c, manifest: m, to: f)
        let obj = try readBack(f)
        #expect((obj["headers"] as? [String: Any])?["Authorization"] as? String == "Bearer sk-new")
        #expect(obj["refreshApiKey"] as? String == "rk-new")
        #expect(obj["testModel"] as? String == "m-1")
        #expect(obj["scheduleTimes"] as? [String] == ["09:00"])
        // 再读回: 凭证一致 (往返无分叉)
        let back = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(back.queryKey == "sk-new")
        #expect(back.refreshKey == "rk-new")
    }

    @Test func writeJWTKeepsOtherFields() throws {
        let f = try writeAuth(#"{"apiUrl":"https://g.example.com","headers":{"authorization":"old","x-trace":"1"},"other":true}"#)
        var m = ProviderManifest(name: "CC-GLM", label: "GLM")
        m.queryAuth = "jwt"
        m.refreshAuth = "bearer"
        var c = ProviderConfig()
        c.queryToken = "jwt-new"
        try ProviderConfigStore.write(c, manifest: m, to: f)
        let obj = try readBack(f)
        let h = obj["headers"] as? [String: Any]
        #expect(h?["authorization"] as? String == "jwt-new")
        #expect(h?["x-trace"] as? String == "1") // 未触及字段保留
        #expect(obj["other"] as? Bool == true)
    }

    @Test func writeEmptyScheduleRemovesKey() throws {
        let f = try writeAuth(#"{"headers":{"Authorization":"Bearer k"},"scheduleTimes":["09:00"]}"#)
        try ProviderConfigStore.write(ProviderConfig(), manifest: ProviderManifest(name: "R", label: "R"), to: f)
        let obj = try readBack(f)
        #expect(obj["scheduleTimes"] == nil) // 清空后字段移除
    }

    // MARK: queryKeyField — 凭证单一事实源 = auth.<field> (cline 形态)

    @Test func writeKeyedFieldWritesTopLevelKey() throws {
        let f = try writeAuth(#"{"apiKey":"old","headers":{"Authorization":"stale","x-trace":"1"},"other":true}"#)
        var m = ProviderManifest(name: "Cline", label: "Cline")
        m.queryAuth = "bearer"
        m.queryKeyField = "apiKey"
        var c = ProviderConfig()
        c.queryKey = "clp_new"
        try ProviderConfigStore.write(c, manifest: m, to: f)
        let obj = try readBack(f)
        #expect(obj["apiKey"] as? String == "clp_new")             // 既有 apiKey 被更新 (非冻结)
        #expect((obj["headers"] as? [String: Any])?["x-trace"] as? String == "1") // headers 保留
        #expect(obj["other"] as? Bool == true)                      // 未知字段保留
        #expect(ProviderConfigStore.read(authFile: f, manifest: m).queryKey == "clp_new")
    }

    @Test func readKeyedFieldAlsoFeedsRefresh() throws {
        // 同一把 Key 兼作查询与调用 (cline): 无 refreshApiKey 时 refresh 回退 queryKey
        let f = try writeAuth(#"{"apiKey":"clp_same"}"#)
        var m = ProviderManifest(name: "Cline", label: "Cline")
        m.queryAuth = "bearer"
        m.queryKeyField = "apiKey"
        m.refreshAuth = "bearer"
        let c = ProviderConfigStore.read(authFile: f, manifest: m)
        #expect(c.queryKey == "clp_same")
        #expect(c.refreshKey == "clp_same")
    }

    @Test func instantiateThenWriteKeyedField() throws {
        // 模板实例化 (auth-template 只有空 apiKey) -> 写新 key -> 文件 auth.apiKey == 新值
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("th-keyed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tdir = tmp.appendingPathComponent("bundle/cline", isDirectory: true)
        try FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
        let tmplManifest = ProviderManifest(name: "Cline", label: "Cline", buckets: [:],
                                            queryAuth: "bearer", queryKeyField: "apiKey")
        try JSONEncoder().encode(tmplManifest).write(to: tdir.appendingPathComponent("manifest.json"))
        try "#!/bin/zsh\n".write(to: tdir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        try #"{"apiKey":"","_note":"keep"}"#
            .write(to: tdir.appendingPathComponent("auth-template.json"), atomically: true, encoding: .utf8)
        let userDir = tmp.appendingPathComponent("user", isDirectory: true)
        let hudDir = tmp.appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        let tmpl = PluginProvider(slug: "cline", manifest: tmplManifest, dir: tdir)
        let m = try PluginGenerator.instantiate(template: tmpl, slug: "cline-me", name: "Cline-Me",
                                               into: userDir, hudDir: hudDir)
        #expect(m.queryKeyField == "apiKey")   // 实例继承模板字段声明
        let af = PluginGenerator.expandPath(m.authFile!)
        var c = ProviderConfigStore.read(authFile: af, manifest: m)
        c.queryKey = "clp_new"
        try ProviderConfigStore.write(c, manifest: m, to: af)

        let obj = try readBack(af)
        #expect(obj["apiKey"] as? String == "clp_new")
        #expect(obj["_note"] as? String == "keep")  // auth 模板未知字段保留
        #expect(obj["headers"] == nil)              // 不凭空造 headers.Authorization
        #expect(ProviderConfigStore.read(authFile: af, manifest: m).queryKey == "clp_new")
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

    @Test @MainActor func incompleteSaveForcesAutoQueryOff() throws {
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
        // 缺 key 的通用自定义账号 (url 合法) → 可保存, autoQuery 被强制 off
        var v = DraftValues()
        v.name = "半配置号"
        v.url = "https://api.example.com"
        v.key = ""            // 执行性缺失
        v.autoQuery = true    // 用户开着 → 保存时强制关
        model.draft = Draft(slug: nil, template: nil, isNew: true, values: v, base: DraftValues())
        model.save()
        #expect(model.topError.isEmpty)                 // 结构无错 → 保存放行
        #expect(engine.allPlugins.contains { $0.slug == "ban-zhi-hao" || $0.manifest.fullName.contains("半配置") })
        #expect(engine.disabledSlugs.contains(engine.allPlugins[0].slug))  // autoQuery 已置 off
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
        #expect(obj["schemaVersion"] as? Int == 1)
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
