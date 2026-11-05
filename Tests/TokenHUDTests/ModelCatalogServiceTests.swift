import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct ModelCatalogServiceTests {
    private func connection(_ baseURL: String = "https://catalog.example.invalid", protocolName: String = "openai",
                            headers: String = "", key: String = "fixture-call-key") -> ModelCatalogConnection {
        ModelCatalogConnection(baseURL: baseURL, protocolName: protocolName, apiKey: key, headers: headers)
    }

    private func fetch(_ connection: ModelCatalogConnection, body: String = #"{"data":[{"id":"chat-model"}]}"#,
                       status: Int = 200, responseHeaders: [String: String] = [:]) async throws -> [String] {
        CatalogURLProtocol.state.reset(status: status, body: Data(body.utf8), headers: responseHeaders)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return try await ModelCatalogService.fetch(connection: connection, configuration: configuration)
    }

    @Test(arguments: [
        ("https://catalog.example.invalid", "https://catalog.example.invalid/v1/models"),
        ("https://catalog.example.invalid/v1/", "https://catalog.example.invalid/v1/models"),
        ("https://catalog.example.invalid/v1/chat/completions", "https://catalog.example.invalid/v1/models"),
        ("https://catalog.example.invalid/api/anthropic/v1/messages", "https://catalog.example.invalid/api/anthropic/v1/models"),
        ("https://catalog.example.invalid/api/anthropic/v1", "https://catalog.example.invalid/api/anthropic/v1/models"),
        ("https://catalog.example.invalid/relay/v1/models?api-version=2025-01", "https://catalog.example.invalid/relay/v1/models?api-version=2025-01")
    ])
    func buildsOnlyTheExactModelsEndpoint(base: String, expected: String) async throws {
        _ = try await fetch(connection(base))
        let request = try #require(CatalogURLProtocol.state.requests.first)
        #expect(request.url?.absoluteString == expected)
        #expect(request.httpMethod == "GET")
        #expect(CatalogURLProtocol.state.requests.count == 1)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-call-key")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.timeoutInterval == 12)
        #expect(request.httpBody == nil)
    }

    @Test(arguments: ["apikey", "auth"])
    func callSnapshotRoutesCatalogBySelectedAuthenticationMode(mode: String) async throws {
        var config = ProviderConfig()
        config.authMode = mode
        config.apiBaseURL = "https://api.openai.com/v1"
        config.refreshProtocol = mode == "auth" ? "responses" : "openai"
        config.refreshKey = mode == "auth" ? "offline-auth-token" : "offline-api-key"
        config.refreshHeader = "Authorization: Bearer <key>"
        config.authModelsURL = "https://chatgpt.com/backend-api/codex/models?client_version=fixture"
        let catalog = ModelCatalogConnection(callConfig: config)
        #expect(catalog.modelsURL == (mode == "auth" ? config.authModelsURL : nil))
        _ = try await fetch(catalog)
        let request = try #require(CatalogURLProtocol.state.requests.first)
        let expectedURL = mode == "auth" ? config.authModelsURL : "https://api.openai.com/v1/models"
        #expect(request.url?.absoluteString == expectedURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(config.refreshKey)")
        #expect(request.httpMethod == "GET")
        #expect(CatalogURLProtocol.state.requests.count == 1)
    }

    @Test func anthropicUsesTheCurrentCallKeyAndProtocolHeaders() async throws {
        _ = try await fetch(connection("https://catalog.example.invalid/api/anthropic/v1", protocolName: "anthropic"))
        let request = try #require(CatalogURLProtocol.state.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-call-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.path == "/api/anthropic/v1/models")
    }

    @Test func currentCustomHeaderTemplateIsUsedWithoutAnExtraAuthScheme() async throws {
        _ = try await fetch(connection(headers: "X-Provider-Key: <key>\nX-Client: TokenHUD"))
        let request = try #require(CatalogURLProtocol.state.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Provider-Key") == "fixture-call-key")
        #expect(request.value(forHTTPHeaderField: "X-Client") == "TokenHUD")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func parsesRealModelFormatsAndSortsWithoutDuplicates() async throws {
        let openAI = try await fetch(connection(), body: #"{"data":[{"id":"z-chat"},{"id":"a-mini"},{"id":"z-chat"},{"id":"  a-mini  "},{"id":""},{"id":4}]}"#)
        #expect(openAI == ["a-mini", "z-chat"])
        let ollama = try await fetch(connection(), body: #"{"models":[{"name":"qwen:small"},{"model":"llama-chat"},{"name":"qwen:small"}]}"#)
        #expect(ollama == ["llama-chat", "qwen:small"])
        let strings = try await fetch(connection(), body: #"["z-chat","a-mini","z-chat"]"#)
        #expect(strings == ["a-mini", "z-chat"])
        let nestedStrings = try await fetch(connection(), body: #"{"models":["z-chat","a-mini"]}"#)
        #expect(nestedStrings == ["a-mini", "z-chat"])
    }

    @Test(arguments: [401, 403, 404, 429, 500])
    func displaysHTTPFailuresAndRedactsTheCallKey(status: Int) async throws {
        do {
            _ = try await fetch(connection(), body: "vendor detail: fixture-call-key was rejected\n" + String(repeating: "long diagnostic ", count: 40), status: status)
            Issue.record("HTTP failure must not produce a model list")
        } catch let error as ModelCatalogError {
            #expect(error.localizedDescription.contains("HTTP \(status)"))
            #expect(error.localizedDescription.contains("vendor detail"))
            #expect(error.localizedDescription.contains(String(repeating: "long diagnostic ", count: 35)))
            #expect(!error.localizedDescription.contains("fixture-call-key"))
            #expect(CatalogURLProtocol.state.requests.count == 1)
        }
    }

    @Test func redirectResponseIsAnErrorWithoutEndpointProbing() async throws {
        do {
            _ = try await fetch(connection(), body: "redirect", status: 302,
                                responseHeaders: ["Location": "https://other.example.invalid/v1/models"])
            Issue.record("Redirect responses must not be accepted")
        } catch let error as ModelCatalogError {
            #expect(error.localizedDescription.contains("重定向"))
            #expect(CatalogURLProtocol.state.requests.count == 1)
            #expect(CatalogURLProtocol.state.requests.first?.url?.host == "catalog.example.invalid")
        }
    }

    @Test func escapedSecretsAndImplicitCookiesAreNotExposed() async throws {
        let key = "fixture/key"
        let encoded = try JSONEncoder().encode(["error": key])
        do {
            _ = try await fetch(connection(key: key), body: String(decoding: encoded, as: UTF8.self), status: 401)
            Issue.record("Authentication failure must throw")
        } catch let error as ModelCatalogError {
            #expect(!error.localizedDescription.contains(key))
            #expect(!error.localizedDescription.contains("fixture\\/key"))
        }
        CatalogURLProtocol.state.reset(status: 200, body: Data(#"{"data":[{"id":"chat"}]}"#.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "fixture-web-session"]
        _ = try await ModelCatalogService.fetch(connection: connection(), configuration: configuration)
        #expect(CatalogURLProtocol.state.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func invalidJSONAndEmptyModelArraysHaveClearErrors() async throws {
        do {
            _ = try await fetch(connection(), body: "<html>fixture-call-key error</html>")
            Issue.record("HTML must not become a model list")
        } catch let error as ModelCatalogError {
            #expect(error.localizedDescription.contains("JSON"))
            #expect(!error.localizedDescription.contains("fixture-call-key"))
        }
        do {
            _ = try await fetch(connection(), body: #"{"data":[]}"#)
            Issue.record("Empty model lists must not invent a default model")
        } catch let error as ModelCatalogError {
            #expect(error == .emptyModels)
        }
        do {
            _ = try await fetch(connection(), body: #"{"error":{"message":"fixture-call-key denied"}}"#)
            Issue.record("Error objects are not model lists")
        } catch let error as ModelCatalogError {
            #expect(error.localizedDescription.contains("格式"))
            #expect(!error.localizedDescription.contains("fixture-call-key"))
        }
    }

    @Test func rejectsOversizedBodiesAndAnnouncedContentLengths() async throws {
        do {
            _ = try await fetch(connection(), body: String(repeating: " ", count: 1_048_577))
            Issue.record("Oversized streaming response must be bounded")
        } catch let error as ModelCatalogError {
            #expect(error == .responseTooLarge)
        }
        do {
            _ = try await fetch(connection(), responseHeaders: ["Content-Length": "1048577"])
            Issue.record("Announced oversized response must be rejected")
        } catch let error as ModelCatalogError {
            #expect(error == .responseTooLarge)
        }
    }

    @Test func invalidConnectionAndWebCookieNeverReachTheNetwork() async throws {
        for value in [connection(key: ""), connection("file:///tmp/model-list"),
                      connection("https://user:password@catalog.example.invalid"),
                      connection(headers: "Cookie: web-session=unrelated"), connection(key: "bad\nkey")] {
            CatalogURLProtocol.state.reset(status: 200, body: Data())
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CatalogURLProtocol.self]
            do {
                _ = try await ModelCatalogService.fetch(connection: value, configuration: configuration)
                Issue.record("Invalid connection must not send a request")
            } catch let error as ModelCatalogError {
                if case .invalidConnection = error {} else { Issue.record("Unexpected error: \(error)") }
                #expect(CatalogURLProtocol.state.requests.isEmpty)
            }
        }
    }

    @Test func timeoutHasAChineseNonConsumptionMessage() async throws {
        CatalogURLProtocol.state.reset(status: 200, body: Data(), failure: URLError(.timedOut))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        do {
            _ = try await ModelCatalogService.fetch(connection: connection(), configuration: configuration)
            Issue.record("Timeout must be reported")
        } catch let error as ModelCatalogError {
            #expect(error.localizedDescription.contains("超时"))
            #expect(error.localizedDescription.contains("没有发送模型测试调用"))
        }
    }

    @Test func recommendationUsesReturnedLightweightChatCandidatesOnly() throws {
        let models = ["text-embedding-nano", "gpt-image-mini", "whisper-small", "tts-mini", "rerank-lite", "video-nano", "chat-model", "gpt-4.1-mini", "claude-haiku", "gpt-4.1-nano"]
        let choice = try #require(ModelCatalogService.recommendation(from: models))
        #expect(choice.model == "gpt-4.1-nano")
        #expect(models.contains(choice.model))
        #expect(choice.reason.contains("名称启发式"))
        #expect(choice.reason.contains("未比较实际价格"))
        #expect(ModelCatalogService.recommendation(from: ["text-embedding-mini", "tts", "whisper-small", "image-flash", "video-lite", "rerank"]) == nil)
    }

    @Test func geminiIsNotMistakenForTheMiniMarkerAndFallbackIsHonest() throws {
        let choice = try #require(ModelCatalogService.recommendation(from: ["gemini-pro", "chat-flash"]))
        #expect(choice.model == "chat-flash")
        let fallback = try #require(ModelCatalogService.recommendation(from: ["z-chat", "a-chat", "a-chat"]))
        #expect(fallback.model == "a-chat")
        #expect(fallback.reason.contains("未识别轻量标记"))
        #expect(fallback.reason.contains("名称启发式"))
        #expect(ModelCatalogService.recommendation(from: []) == nil)
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.state.record(request)
        if let failure = fixture.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    struct Stub {
        let status: Int
        let body: Data
        let headers: [String: String]
        let failure: URLError?
    }
    final class FixtureState: @unchecked Sendable {
        private let lock = NSLock()
        private var stub = Stub(status: 200, body: Data(), headers: [:], failure: nil)
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        func reset(status: Int, body: Data, headers: [String: String] = [:], failure: URLError? = nil) {
            lock.lock(); defer { lock.unlock() }
            stub = Stub(status: status, body: body, headers: headers, failure: failure)
            recorded = []
        }
        func record(_ request: URLRequest) -> Stub {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            return stub
        }
    }
}
