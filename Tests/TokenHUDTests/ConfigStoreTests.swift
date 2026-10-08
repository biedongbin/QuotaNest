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

    @Test func scheduleTimeFormat() {
        // 与 EditForm.isValidScheduleTime 一致: HH:MM 24h 制
        #expect(EditForm.isValidScheduleTime("09:00"))
        #expect(EditForm.isValidScheduleTime("23:59"))
        #expect(!EditForm.isValidScheduleTime("9:00"))   // 非 2 位
        #expect(!EditForm.isValidScheduleTime("24:00"))  // 时越界
        #expect(!EditForm.isValidScheduleTime("09:60"))  // 分越界
        #expect(!EditForm.isValidScheduleTime("abc"))
        #expect(!EditForm.isValidScheduleTime(""))
    }
}
