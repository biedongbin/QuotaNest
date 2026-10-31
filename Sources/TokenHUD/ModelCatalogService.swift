import Foundation

/// Only the account's API-call connection belongs here; quota/web credentials are unrelated.
struct ModelCatalogConnection: Equatable, Sendable {
    let baseURL: String
    let protocolName: String
    let apiKey: String
    let headers: String
}

struct ModelRecommendation: Equatable, Sendable {
    let model: String
    let reason: String
}

enum ModelCatalogError: LocalizedError, Equatable, Sendable {
    case invalidConnection(String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case responseTooLarge
    case emptyModels
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConnection(let message), .invalidResponse(let message), .transport(let message):
            return message
        case .responseTooLarge:
            return "模型列表响应超过 1 MiB，已停止读取；请检查供应商模型接口。"
        case .emptyModels:
            return "供应商返回了空模型列表，请手动填写测试模型，或检查当前 API Key 的模型访问权限。"
        case .http(let status, let body):
            let explanation: String
            switch status {
            case 401: explanation = "模型列表认证失败（HTTP 401），请检查当前调用 API Key。"
            case 403: explanation = "供应商拒绝访问模型列表（HTTP 403），请检查当前调用凭证的权限。"
            case 404: explanation = "供应商未提供此标准模型列表接口（HTTP 404），可手动填写测试模型。"
            case 429: explanation = "模型列表请求受到限流（HTTP 429），请稍后重试。"
            case 300..<400: explanation = "模型列表接口要求重定向（HTTP \(status)），已停止请求；请核对 API Base URL。"
            default: explanation = "拉取模型列表失败（HTTP \(status)）。"
            }
            return body.isEmpty ? explanation : explanation + "\n\n服务端响应：\n" + body
        }
    }
}

enum ModelCatalogService {
    private static let maximumResponseBytes = 1_048_576
    private static let lightweightMarkers = ["nano", "mini", "haiku", "flash", "lite", "small"]
    private static let nonChatMarkers = ["embed", "tts", "whisper", "rerank", "image", "video", "dall-e", "dalle", "diffusion", "flux", "sora", "veo", "transcri", "speech"]

    static func fetch(connection: ModelCatalogConnection) async throws -> [String] {
        try await fetch(connection: connection, configuration: .ephemeral)
    }

    /// The configuration seam lets URLProtocol fixtures exercise real URLSession requests offline.
    static func fetch(connection: ModelCatalogConnection, configuration: URLSessionConfiguration) async throws -> [String] {
        let request = try request(for: connection)
        guard let setup = configuration.copy() as? URLSessionConfiguration else {
            throw ModelCatalogError.invalidConnection("无法创建模型列表网络配置。")
        }
        setup.timeoutIntervalForRequest = 12
        setup.timeoutIntervalForResource = 15
        setup.httpCookieStorage = nil
        setup.httpShouldSetCookies = false
        setup.httpAdditionalHeaders = nil
        setup.urlCredentialStorage = nil
        setup.urlCache = nil
        let session = URLSession(configuration: setup, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ModelCatalogError.invalidResponse("模型接口没有返回 HTTP 响应。")
            }
            guard response.expectedContentLength <= maximumResponseBytes else {
                throw ModelCatalogError.responseTooLarge
            }
            var body = Data()
            body.reserveCapacity(Int(max(0, response.expectedContentLength)))
            for try await byte in bytes {
                guard body.count < maximumResponseBytes else { throw ModelCatalogError.responseTooLarge }
                body.append(byte)
            }
            let text = redacted(String(decoding: body, as: UTF8.self), connection: connection)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (200..<300).contains(http.statusCode) else {
                throw ModelCatalogError.http(status: http.statusCode, body: text)
            }
            return try models(in: body, safeText: text)
        } catch let error as ModelCatalogError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ModelCatalogError.transport("模型列表请求超时，请稍后重试；本次没有发送模型测试调用。")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ModelCatalogError.transport("无法读取模型列表：" + redacted(error.localizedDescription, connection: connection))
        }
    }

    static func recommendation(from models: [String]) -> ModelRecommendation? {
        let candidates = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { model in
                !model.isEmpty && !nonChatMarkers.contains { model.lowercased().contains($0) }
            }.sorted()
        let ranked = candidates.compactMap { model -> (model: String, marker: String, rank: Int)? in
            let tokens = model.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard let rank = lightweightMarkers.firstIndex(where: { tokens.contains($0) }) else { return nil }
            return (model, lightweightMarkers[rank], rank)
        }.sorted { $0.rank == $1.rank ? $0.model < $1.model : $0.rank < $1.rank }
        if let first = ranked.first {
            return ModelRecommendation(model: first.model,
                reason: "按返回模型名称中的“\(first.marker)”轻量标记优先建议用于测试；这是名称启发式，未比较实际价格，也未验证接口兼容性。")
        }
        guard let model = candidates.first else { return nil }
        return ModelRecommendation(model: model,
            reason: "未识别轻量标记，按名称顺序从未被识别为专用非对话模型的返回项中建议；仅为名称启发式，接口兼容性和实际价格尚未验证。")
    }

    private static func request(for connection: ModelCatalogConnection) throws -> URLRequest {
        let protocolName = connection.protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["openai", "anthropic"].contains(protocolName) else {
            throw ModelCatalogError.invalidConnection("请先选择 OpenAI 或 Anthropic 调用协议。")
        }
        let key = connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ModelCatalogError.invalidConnection("请先填写当前调用 API Key，再拉取模型列表。") }
        guard key.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ModelCatalogError.invalidConnection("调用 API Key 包含非法控制字符，请检查凭证。")
        }
        var request = URLRequest(url: try modelsURL(connection.baseURL), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let suppliedHeaders = connection.headers.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = suppliedHeaders.isEmpty
            ? (protocolName == "anthropic" ? "x-api-key: <key>\nanthropic-version: 2023-06-01" : "Authorization: Bearer <key>")
            : suppliedHeaders
        for line in headers.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.contains("\r") else {
                throw ModelCatalogError.invalidConnection("调用请求头模板格式错误，应为每行“名称: 值”。")
            }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "cookie" {
                throw ModelCatalogError.invalidConnection("模型列表仅使用调用 API Key，不使用网页 Cookie；请检查调用认证请求头。")
            }
        }
        RefreshTrigger.applyHeaders(&request, headers, key: key, protocol: protocolName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func modelsURL(_ baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              components.user == nil, components.password == nil else {
            throw ModelCatalogError.invalidConnection("请填写有效的 HTTP(S) API Base URL，地址中不要包含用户名或密码。")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for endpoint in ["/chat/completions", "/messages"] where path.hasSuffix(endpoint) {
            path.removeLast(endpoint.count)
            break
        }
        if !path.hasSuffix("/models") {
            path += path.hasSuffix("/v1") ? "/models" : "/v1/models"
        }
        components.percentEncodedPath = path
        components.fragment = nil
        guard let url = components.url else { throw ModelCatalogError.invalidConnection("无法生成模型列表接口地址，请检查 API Base URL。") }
        return url
    }

    private static func models(in body: Data, safeText: String) throws -> [String] {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) }
        catch {
            throw ModelCatalogError.invalidResponse("模型接口返回的内容不是有效 JSON。" + (safeText.isEmpty ? "响应体为空。" : "\n\n服务端响应：\n" + safeText))
        }
        let rows: [Any]?
        if let object = json as? [String: Any] {
            rows = object["data"] as? [Any] ?? object["models"] as? [Any]
        } else { rows = json as? [Any] }
        guard let rows else {
            throw ModelCatalogError.invalidResponse("模型接口未返回支持的模型列表格式（data 或 models 数组）。\n\n服务端响应：\n" + safeText)
        }
        let ids = rows.compactMap { item -> String? in
            if let value = item as? String { return value }
            guard let object = item as? [String: Any] else { return nil }
            return object["id"] as? String ?? object["name"] as? String ?? object["model"] as? String
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let result = Array(Set(ids)).sorted()
        guard !result.isEmpty else { throw ModelCatalogError.emptyModels }
        return result
    }

    private static func redacted(_ text: String, connection: ModelCatalogConnection) -> String {
        let key = connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return text }
        var result = text.replacingOccurrences(of: key, with: "[已隐藏 API Key]")
        if let data = try? JSONEncoder().encode(key), let quoted = String(data: data, encoding: .utf8) {
            let escaped = String(quoted.dropFirst().dropLast())
            if !escaped.isEmpty { result = result.replacingOccurrences(of: escaped, with: "[已隐藏 API Key]") }
        }
        return result
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
