import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct RefreshSessionTests {
    private func manifest() throws -> ProviderManifest {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenHUD/providers/opencode-go/manifest.json")
        return try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: url))
    }

    private func setup() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionHeaderProtocol.self]
        return configuration
    }

    @Test func realRefreshRejectsMissingSessionOrClientIdentity() async throws {
        let m = try manifest()
        var config = ProviderConfigStore.read(authFile: URL(fileURLWithPath: "/nonexistent/tokenhud-session-fixture.json"), manifest: m)
        config.refreshUrl = "https://session.example.invalid/chat/completions"
        config.refreshKey = "fixture-key"
        let session = URLSession(configuration: setup())
        defer { session.invalidateAndCancel() }
        SessionHeaderProtocol.state.reset()
        for header in ["Authorization: Bearer <key>\nUser-Agent: TokenHUD/1.0",
                       "Authorization: Bearer <key>\nx-opencode-session: tokenhud-<session>"] {
            config.refreshHeader = header
            let result = await RefreshTrigger.testRefresh(config: config, session: session)
            #expect(result?.contains("HTTP 400") == true)
        }
        #expect(SessionHeaderProtocol.state.requests.count == 2)
    }

    @Test func manualAndScheduledCallsAndModelsUseDeclaredSessionHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("account.json")
        let authData = Data(#"{"refreshApiKey":"fixture-key","authMode":"apikey"}"#.utf8)
        try authData.write(to: auth)
        var m = try manifest()
        #expect(m.refreshHeader?.contains("User-Agent: TokenHUD/1.0") == true)
        #expect(m.refreshHeader?.contains("x-opencode-session: tokenhud-<session>") == true)
        #expect(m.inheritQueryHeader == "Authorization: Bearer <key>")
        m.refreshUrl = "https://session.example.invalid/v1/chat/completions"
        m.refreshHeader = try #require(m.refreshHeader) + "\nX-Session-Echo: <session>/<session>"
        let config = ProviderConfigStore.read(authFile: auth, manifest: m)
        let session = URLSession(configuration: setup())
        defer { session.invalidateAndCancel() }
        SessionHeaderProtocol.state.reset()

        let manual = await RefreshTrigger.testRefresh(config: config, session: session)
        #expect(manual?.hasPrefix("✓") == true)
        // The scheduler's default trigger delegates here, including its auth-file read.
        let scheduled = await RefreshTrigger.trigger(manifest: m, authFile: auth, session: session)
        #expect(scheduled?.hasPrefix("✓") == true)
        let models = try await ModelCatalogService.fetch(connection: ModelCatalogConnection(callConfig: config), configuration: setup())
        #expect(models == ["fixture-model"])

        let requests = SessionHeaderProtocol.state.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET"])
        var sessions: Set<String> = []
        for request in requests {
            #expect(request.url?.host == "session.example.invalid")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TokenHUD/1.0")
            let value = try #require(request.value(forHTTPHeaderField: "x-opencode-session"))
            #expect(value.hasPrefix("tokenhud-"))
            let id = String(value.dropFirst("tokenhud-".count))
            #expect(UUID(uuidString: id) != nil)
            #expect(request.value(forHTTPHeaderField: "X-Session-Echo") == "\(id)/\(id)")
            sessions.insert(value)
        }
        #expect(sessions.count == 3)
        #expect(try Data(contentsOf: auth) == authData)
    }

    @Test func undeclaredVendorAndQuotaHeadersDoNotGainSessions() throws {
        var config = ProviderConfig()
        config.refreshUrl = "https://other.example.invalid/v1/chat/completions"
        config.refreshProtocol = "openai"
        config.refreshKey = "fixture-key"
        config.refreshHeader = "Authorization: Bearer <key>"
        config.testModel = "fixture-model"
        let request = try RefreshTrigger.callRequest(config: config)
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
        let m = try manifest()
        config.inheritQueryURL = m.inheritQueryUrl
        config.inheritQueryHeader = m.inheritQueryHeader
        config.quotaAuthModes = m.quotaAuthModes
        let quota = try ProviderAuthentication.resolveQuota(config)
        let quotaURL = try #require(URL(string: "https://session.example.invalid/usage"))
        var quotaRequest = URLRequest(url: quotaURL)
        RefreshTrigger.applyHeaders(&quotaRequest, quota.queryHeader, key: quota.queryKey, protocol: quota.refreshProtocol)
        #expect(quotaRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(quotaRequest.value(forHTTPHeaderField: "x-opencode-session") == nil)
    }
}

private final class SessionHeaderProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        let hasSession = request.value(forHTTPHeaderField: "x-opencode-session")?.hasPrefix("tokenhud-") == true
        let hasIdentity = request.value(forHTTPHeaderField: "User-Agent") == "TokenHUD/1.0"
        let status = hasSession && hasIdentity ? 200 : 400
        let body = status == 400 ? #"{"error":"MissingSessionID or client identity"}"#
            : request.httpMethod == "GET" ? #"{"data":[{"id":"fixture-model"}]}"# : #"{"choices":[{"message":{"content":"OK"}}]}"#
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        func reset() { lock.lock(); defer { lock.unlock() }; recorded = [] }
        func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; recorded.append(request) }
    }
}
