import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
struct ProviderAuthenticationTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-auth-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func login(_ file: URL, token: String = "opaque-auth-token-A", account: String = "account-A") throws {
        try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": token, "account_id": account]])
            .write(to: file)
    }
    private func authConfig(_ file: URL) -> ProviderConfig {
        var c = ProviderConfig()
        c.authMode = "auth"
        c.credentialSource = ProviderCredentialSource(file: file.path, tokenPath: "tokens.access_token",
            headerPaths: ["chatgpt-account-id": "tokens.account_id"], requiredValues: ["auth_mode": "chatgpt"])
        c.authCallURL = "https://subscription.example.test/backend-api/codex/responses"
        c.authCallProtocol = "responses"
        c.authCallHeader = "Authorization: Bearer <key>\nOpenAI-Beta: responses=experimental"
        c.queryUrl = "https://subscription.example.test/usage"
        c.quotaAuthModes = ["auth"]
        c.queryAuth = "header"
        c.testModel = "returned-model"
        return c
    }

    @Test func legacyAuthFilePointerMigratesWithoutChangingTheAccount() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let oldFile = dir.appendingPathComponent("old-login.json")
        let newFile = dir.appendingPathComponent("new-login.json")
        let defaultFile = dir.appendingPathComponent("default-login.json")
        try login(oldFile, token: "old-account-token")
        try login(newFile, token: "explicit-account-token")
        try login(defaultFile, token: "default-account-token")
        let providerDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenHUD/providers/gpt")
        var manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: providerDir.appendingPathComponent("manifest.json")))
        #expect(manifest.credentialSource?.fileConfigKey == "codexAuthFile")
        manifest.credentialSource?.file = defaultFile.path
        manifest.credentialSource?.environmentDirectory = nil
        let account = dir.appendingPathComponent("account.json")
        var json: [String: Any] = ["schemaVersion": 2, "authMode": "auth", "codexAuthFile": oldFile.path]
        try JSONSerialization.data(withJSONObject: json).write(to: account)
        let old = ProviderConfigStore.read(authFile: account, manifest: manifest)
        #expect(old.authCredentialFile == oldFile.path)
        #expect(ProviderAuthentication.credentialFileURL(for: old)?.path == oldFile.path)
        #expect(try ProviderAuthentication.resolveCall(old).refreshKey == "old-account-token")
        json["authCredentialFile"] = newFile.path
        try JSONSerialization.data(withJSONObject: json).write(to: account)
        var overridden = ProviderConfigStore.read(authFile: account, manifest: manifest)
        #expect(try ProviderAuthentication.resolveCall(overridden).refreshKey == "explicit-account-token")
        overridden.authCredentialFile = ""
        try ProviderConfigStore.write(overridden, manifest: manifest, to: account)
        let reset = ProviderConfigStore.read(authFile: account, manifest: manifest)
        #expect(reset.authCredentialFile.isEmpty)
        #expect(try ProviderAuthentication.resolveCall(reset).refreshKey == "default-account-token")
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: account)) as? [String: Any])
        #expect(saved["codexAuthFile"] as? String == oldFile.path)
        let fresh = ProviderConfigStore.read(authFile: providerDir.appendingPathComponent("auth-template.json"), manifest: manifest)
        #expect(fresh.authMode == "auth")
    }

    @Test(arguments: ["glm", "cline", "ollama", "opencode-go"])
    func supplierAPIKeyCallAndQuotaShareTheSameBase(_ supplier: String) throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = repository.appendingPathComponent("Sources/TokenHUD/providers/\(supplier)/manifest.json")
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        var config = ProviderConfigStore.read(authFile: dir.appendingPathComponent("account.json"), manifest: manifest)
        config.authMode = "apikey"
        config.refreshKey = "fixture-shared-base-A"
        let call = try ProviderAuthentication.resolveCall(config)
        let quota = try ProviderAuthentication.resolveQuota(config)
        #expect(call.refreshKey == config.refreshKey)
        #expect(quota.queryKey == config.refreshKey)
        let urls = ["glm": "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
                    "cline": "https://api.cline.bot/api/v1/users/me/plan/usage-limits",
                    "ollama": "https://ollama.com/api/balance", "opencode-go": "https://opencode.ai/zen/go/v1/usage"]
        #expect(quota.queryUrl == urls[supplier])
        var request = URLRequest(url: try #require(URL(string: quota.queryUrl)))
        RefreshTrigger.applyHeaders(&request, quota.queryHeader, key: quota.queryKey, protocol: quota.refreshProtocol)
        #expect(request.value(forHTTPHeaderField: "Authorization") == (supplier == "glm" ? config.refreshKey : "Bearer \(config.refreshKey)"))
        #expect(manifest.credentialSource == nil)
        config.authMode = "auth"
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveCall(config) }
    }

    @Test func apiKeyQuotaInheritsBaseInsteadOfStaleWebCredentials() throws {
        var c = ProviderConfig()
        c.refreshKey = "base-api-key"
        c.queryKey = "old-query-key"
        c.inheritQueryURL = "https://api.example.test/usage"
        c.inheritQueryHeader = "Authorization: <key>"
        let q = try ProviderAuthentication.resolveQuota(c)
        #expect(q.queryKey == "base-api-key")
        #expect(q.queryHeader == "Authorization: <key>")
        #expect(q.queryUrl == "https://api.example.test/usage")
        #expect(c.queryKey == "old-query-key")
    }

    @Test func authSnapshotIsReadOnlyAndStableUntilNextRequest() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.json")
        try login(file)
        let c = authConfig(file)
        let resolved = try ProviderAuthentication.resolveCall(c)
        #expect(resolved.refreshKey == "opaque-auth-token-A")
        #expect(resolved.refreshHeader.contains("chatgpt-account-id: account-A"))
        #expect(resolved.refreshProtocol == "responses")
        #expect(resolved.credentialsResolved)
        try login(file, token: "opaque-auth-token-B", account: "account-B")
        #expect(try ProviderAuthentication.resolveCall(resolved).refreshKey == "opaque-auth-token-A")
        #expect(try ProviderAuthentication.resolveCall(c).refreshKey == "opaque-auth-token-B")
        #expect(c.refreshKey.isEmpty)
        #expect(throws: ProviderAuthenticationError.self) {
            try ProviderConfigStore.write(resolved, manifest: ProviderManifest(name: "fixture", label: "fixture"),
                                          to: dir.appendingPathComponent("account.json"))
        }
    }

    @Test func quotaDoesNotRequireAnAuthModelEndpointButRejectsAnotherAuthenticationMode() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.json"); try login(file)
        var c = authConfig(file); c.authCallURL = nil
        #expect(try ProviderAuthentication.resolveQuota(c).queryKey == "opaque-auth-token-A")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveCall(c) }
        c.authMode = "apikey"; c.refreshKey = "api-key"
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(c) }
    }

    @Test func oldIndependentCredentialsAreRemovedWithoutChangingBaseAuthentication() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("account.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "refreshApiKey": "base-key", "queryKey": "query-key",
            "headers": ["authorization": "old-web-token"], "cookieAuth": "old-web-cookie", "quotaMode": "none",
            "quotaCredentialMode": "legacy"]).write(to: file)
        let manifest = ProviderManifest(name: "fixture", label: "fixture", quotaMode: "script")
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        #expect(config.authMode == "apikey" && config.quotaMode == "none")
        #expect(config.queryKey.isEmpty)
        #expect(try ProviderAuthentication.resolveQuota(config).queryKey == "base-key")
        try ProviderConfigStore.write(config, manifest: manifest, to: file)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["quotaCredentialMode"] == nil && saved["queryKey"] == nil && saved["cookieAuth"] == nil)
        #expect(saved["headers"] == nil)
        #expect(saved["refreshApiKey"] as? String == "base-key")
    }

    @Test func authSourceCannotBeUsedAsWritableAccountConfiguration() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.json")
        try login(file)
        let original = try Data(contentsOf: file)
        let config = authConfig(file)
        let manifest = ProviderManifest(name: "fixture", label: "fixture", credentialSource: config.credentialSource)
        #expect(throws: ProviderAuthenticationError.self) {
            try ProviderConfigStore.write(config, manifest: manifest, to: file)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func apiKeySnapshotReplacesEveryOldQueryIdentity() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("account.json")
        try JSONSerialization.data(withJSONObject: ["refreshApiKey": "base-key", "queryKey": "old-key",
            "apiKey": "old-api-key", "cookieAuth": "old-cookie", "queryToken": "old-token", "accountId": "old-account",
            "quotaCredentialMode": "legacy", "headers": ["authorization": "old-jwt", "Cookie": "old-cookie"]]).write(to: file)
        let original = try Data(contentsOf: file)
        let manifest = ProviderManifest(name: "fixture", label: "fixture", queryUrl: "https://api.example.test/usage",
            queryAuth: "bearer", queryKeyField: "apiKey")
        let config = ProviderConfigStore.read(authFile: file, manifest: manifest)
        let snapshot = try ProviderQuerySnapshot.make(config: config, manifest: manifest, originalAuth: file)
        defer { snapshot.cleanup() }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.file)) as? [String: Any])
        #expect(object["queryKey"] as? String == "base-key")
        #expect(object["apiKey"] as? String == "base-key")
        #expect(object["cookieAuth"] == nil && object["queryToken"] == nil && object["accountId"] == nil)
        let headers = try #require(object["headers"] as? [String: String])
        #expect(headers.first { $0.key.lowercased() == "authorization" }?.value == "Bearer base-key")
        #expect(!headers.keys.contains { $0.lowercased() == "cookie" })
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func instantiatePreservesDeclaredAuthCapabilities() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = ProviderCredentialSource(file: "/fixture/login.json", tokenPath: "tokens.access_token")
        let manifest = ProviderManifest(name: "Auth", label: "Auth", authMode: "auth", quotaMode: "script",
            quotaAuthModes: ["auth"], credentialSource: source, authCallUrl: "https://auth.example.test/responses",
            authCallProtocol: "responses", authModelsUrl: "https://auth.example.test/models", inheritQueryUrl: "https://auth.example.test/usage")
        let templateDir = dir.appendingPathComponent("type")
        try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
        try "exit 1".write(to: templateDir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let copy = try PluginGenerator.instantiate(template: PluginProvider(slug: "auth-type", manifest: manifest, dir: templateDir),
            slug: "account-one", name: "One", into: dir.appendingPathComponent("instances"), hudDir: dir.appendingPathComponent("hud"))
        #expect(copy.credentialSource == source)
        #expect(copy.authCallUrl == manifest.authCallUrl && copy.authModelsUrl == manifest.authModelsUrl)
        #expect(copy.quotaAuthModes == ["auth"])
    }

    @Test func responsesRequestUsesAuthEndpointAccountAndSupportedBody() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.json"); try login(file)
        let request = try RefreshTrigger.callRequest(config: authConfig(file))
        #expect(request.url?.absoluteString == "https://subscription.example.test/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-auth-token-A")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account-A")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["max_tokens"] == nil && body["max_output_tokens"] == nil)
        #expect(body["input"] as? [[String: Any]] != nil)
        #expect(RefreshTrigger.responsesMessage(Data("data: {\"type\":\"response.completed\"}\n\n".utf8), redacting: []).hasPrefix("✓"))
        #expect(!RefreshTrigger.responsesMessage(Data("data: {\"type\":\"response.failed\"}\n\n".utf8), redacting: []).hasPrefix("✓"))
    }

    @Test func authResponsesExecutesThroughTheInjectedTransport() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.json"); try login(file)
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenHUD/providers/gpt/manifest.json")
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        var config = ProviderConfigStore.applyingManifest(manifest, to: authConfig(file))
        config.authCredentialFile = file.path
        config.authCallURL = "https://subscription.example.test/backend-api/codex/responses"
        let setup = URLSessionConfiguration.ephemeral
        setup.protocolClasses = [AuthTransportProtocol.self]
        let session = URLSession(configuration: setup)
        defer { session.invalidateAndCancel() }
        let replies: [(Int, String, Bool)] = [
            (200, "data: {\"type\":\"response.completed\"}\n\n", true),
            (200, "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"fixture failure\"}}\n\n", false),
            (200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n", false),
            (401, "{\"error\":\"opaque-auth-token-A refused\"}", false),
        ]
        for (status, response, succeeded) in replies {
            AuthTransportProtocol.fixture.reset(status: status, body: Data(response.utf8))
            let responseText = await RefreshTrigger.testRefresh(config: config, session: session)
            let result = try #require(responseText)
            #expect(result.hasPrefix("✓") == succeeded)
            #expect(!result.contains("opaque-auth-token-A"))
            if status == 401 { #expect(result.contains("HTTP 401")) }
            if response.contains("fixture failure") { #expect(result.contains("fixture failure")) }
            let requests = AuthTransportProtocol.fixture.requests
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == config.authCallURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-auth-token-A")
            #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account-A")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
            #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
            #expect(request.value(forHTTPHeaderField: "version") == "0.159.0")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            let bodyData = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(body["model"] as? String == config.testModel)
            #expect(body["stream"] as? Bool == true && body["store"] as? Bool == false)
            #expect(body["max_tokens"] == nil && body["max_output_tokens"] == nil)
            let messages = try #require(body["input"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            #expect(content.first?["text"] as? String == config.testPrompt)
        }
    }

    @Test func inheritedScriptSnapshotIsRemovedAndNeverOverwritesTheAccount() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let loginFile = dir.appendingPathComponent("login.json"); try login(loginFile)
        let account = dir.appendingPathComponent("account.json")
        var c = authConfig(loginFile); c.quotaMode = "script"
        let m = ProviderManifest(name: "Auth", label: "Auth", authFile: account.path, queryUrl: c.queryUrl,
            queryAuth: "header", authMode: "auth", quotaMode: "script", quotaAuthModes: ["auth"], credentialSource: c.credentialSource)
        try ProviderConfigStore.write(c, manifest: m, to: account)
        let original = try Data(contentsOf: account)
        let script = """
        cp "$TOKENHUD_AUTH_FILE" "\(dir.path)/captured.json"
        printf '%s' "$TOKENHUD_AUTH_FILE" > "\(dir.path)/snapshot-path"
        printf '%s' 'opaque-auth-token-A' >&2
        exit 1
        """
        let providers = dir.appendingPathComponent("providers")
        try PluginGenerator.writePlugin(slug: "one", manifest: m, script: script, into: providers)
        let p = PluginProvider(slug: "one", manifest: m, dir: providers.appendingPathComponent("one"))
        let runner = ProviderRunner(nodePath: nil, logDir: dir)
        #expect(await runner.run(p) == nil)
        let captured = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("captured.json"))) as? [String: Any])
        #expect(captured["queryKey"] as? String == "opaque-auth-token-A")
        #expect(captured["accountId"] as? String == "account-A")
        let path = try String(contentsOf: dir.appendingPathComponent("snapshot-path"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: account) == original)
        let log = try String(contentsOf: dir.appendingPathComponent(".one-usage-stderr.log"), encoding: .utf8)
        #expect(!log.contains("opaque-auth-token-A"))
    }
}

/// Private to this suite: the catalog suite's URLProtocol fixture is private and cannot be
/// shared safely because the two suites may execute concurrently.
private final class AuthTransportProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            let bufferSize = 2048
            var data = Data(), buffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                let count = stream.read(&buffer, maxLength: bufferSize)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            captured.httpBody = data
        }
        let (status, body) = Self.fixture.record(captured)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var body = Data()
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        func reset(status: Int, body: Data) {
            lock.lock(); defer { lock.unlock() }
            self.status = status; self.body = body; recorded = []
        }
        func record(_ request: URLRequest) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request); return (status, body)
        }
    }
}
