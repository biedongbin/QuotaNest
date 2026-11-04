import Foundation

/// 触发额度刷新/测试: 向服务商发请求
/// 配置从 auth 文件读 (ProviderConfigStore), 协议差异由 manifest 声明
/// 协议: anthropic (Messages API) / openai (Chat Completions), 由 config.refreshProtocol 决定
enum RefreshTrigger {
    /// 上栏测试: 发查询请求 (GET url + header), 看是否返回数据
    static func testQuery(config original: ProviderConfig) async -> String? {
        let target = original.inheritQueryURL ?? original.queryUrl
        guard !target.isEmpty else { return "未配置查询 url" }
        guard validHTTPURL(target) != nil else { return "查询 url 非法" }
        let config: ProviderConfig
        do { config = try ProviderAuthentication.resolveQuota(original) }
        catch { return error.localizedDescription }
        guard !config.queryUrl.isEmpty else { return "未配置查询 url" }
        let key = config.queryKey
        guard !key.isEmpty else { return "未配置查询凭证" }
        // P0: url 非法时 URL(string:) 返回 nil, 强解包会 crash 整个 App
        guard let u = URL(string: config.queryUrl) else { return "查询 url 非法" }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        applyHeaders(&req, config.queryHeader, key: key, protocol: config.refreshProtocol)
        return await send(req, redacting: [config.queryKey])
    }

    /// 下栏测试/触发刷新: 发 chat 请求 (POST url + header + model + prompt)
    static func testRefresh(config: ProviderConfig) async -> String? {
        await testRefresh(config: config, session: nil)
    }

    static func callRequest(config: ProviderConfig) throws -> URLRequest {
        let config = try ProviderAuthentication.resolveCall(config)
        guard !config.refreshUrl.isEmpty else { throw ProviderAuthenticationError(message: "未配置刷新 url") }
        guard let url = validHTTPURL(config.refreshUrl) else { throw ProviderAuthenticationError(message: "刷新 url 非法") }
        guard !config.testModel.isEmpty else { throw ProviderAuthenticationError(message: "未配置测试模型") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request, config.refreshHeader, key: config.refreshKey, protocol: config.refreshProtocol)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any]
        if config.refreshProtocol == "responses" {
            body = ["model": config.testModel, "instructions": "Reply briefly to the user.",
                "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": config.testPrompt]]]],
                "store": false, "stream": true]
            // The subscription Responses endpoint rejects max_output_tokens (Magpie codexBody).
            if config.authMode != "auth" { body["max_output_tokens"] = config.testMaxTokens }
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else if ["anthropic", "openai"].contains(config.refreshProtocol) {
            body = ["model": config.testModel, "max_tokens": config.testMaxTokens,
                    "messages": [["role": "user", "content": config.testPrompt]]]
        } else { throw ProviderAuthenticationError(message: "该调用协议尚未支持") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Session injection is for offline URLProtocol tests; regular calls share this same path.
    static func testRefresh(config: ProviderConfig, session: URLSession?) async -> String? {
        if config.authMode == "apikey" {
            guard !config.refreshUrl.isEmpty else { return "未配置刷新 url" }
            guard validHTTPURL(config.refreshUrl) != nil else { return "刷新 url 非法" }
        }
        do {
            let resolved = try ProviderAuthentication.resolveCall(config)
            let request = try callRequest(config: resolved)
            return await send(request, redacting: [resolved.refreshKey], session: session,
                              responsesStream: resolved.refreshProtocol == "responses")
        } catch { return error.localizedDescription }
    }

    private static func validHTTPURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    /// 触发额度刷新 (兼容旧调用: 用 auth 文件读配置)
    static func trigger(manifest: ProviderManifest, authFile: URL, session: URLSession? = nil) async -> String? {
        var config = ProviderConfigStore.read(authFile: authFile, manifest: manifest)
        // auth 文件无 testModel 时回退 manifest 默认, 否则 POST body model 为空不触发计费
        if config.testModel.isEmpty {
            config.testModel = manifest.refreshModel
        }
        if config.testPrompt.isEmpty {
            config.testPrompt = manifest.testPrompt ?? ProviderConfig.defaultPrompt
        }
        return await testRefresh(config: config, session: session)
    }

    /// 每次调用代表独立单轮 conversation；同一模板中的 <session> 共用一个 UUID。
    /// 按协议应用 header: 解析 header 文本 (每行 "k: v"), 替换 <key>/<session> 占位符
    /// anthropic 额外加 anthropic-version (internal 供测试)
    static func applyHeaders(_ req: inout URLRequest, _ headerStr: String, key: String, protocol: String) {
        let sessionID = headerStr.contains("<session>") ? UUID().uuidString : ""
        let headers = headerStr.replacingOccurrences(of: "<session>", with: sessionID)
        for line in headers.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "<key>", with: key)
            req.setValue(v, forHTTPHeaderField: parts[0].trimmingCharacters(in: .whitespaces))
        }
        if `protocol` == "anthropic" {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    private static func send(_ req: URLRequest, redacting credentials: [String], session supplied: URLSession? = nil,
                             responsesStream: Bool = false) async -> String? {
        var r = req
        r.timeoutInterval = 20  // P1-5: 显式超时 (默认 60s 太久, 请求可能已发出但回包迟到)
        do {
            let session = supplied ?? URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            defer { if supplied == nil { session.invalidateAndCancel() } }
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return "无响应" }
            if responsesStream && http.statusCode == 200 {
                return responsesMessage(data, redacting: credentials)
            }
            return responseMessage(statusCode: http.statusCode, body: data, redacting: credentials)
        } catch {
            return Self.describe(error: error)  // 网络类 → 结果不确定 (可能已消费)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func responsesMessage(_ data: Data, redacting credentials: [String]) -> String {
        var completed = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if ["error", "response.failed", "response.incomplete"].contains(type ?? "") {
                return "模型调用未完成：" + responseMessage(statusCode: 400, body: data, redacting: credentials)
            }
            if type == "response.completed" { completed = true }
        }
        return completed ? "✓ Responses 调用完成" : "结果不确定，可能已消费：未收到完整 Responses 完成事件，请查询真实额度确认"
    }

    /// Display up to 1 MiB of response text; make the bound explicit when exceeded.
    static let maximumResponseBodyBytes = 1_048_576

    static func responseMessage(statusCode: Int, body: Data, redacting credentials: [String] = []) -> String {
        if statusCode == 200 && body.isEmpty { return emptyBodyMessage }
        var safeText = String(decoding: body, as: UTF8.self)
        for credential in credentials where !credential.isEmpty {
            safeText = safeText.replacingOccurrences(of: credential, with: "[已隐藏]")
        }
        safeText = ProviderRunner.redact(safeText)
        let safeData = Data(safeText.utf8)
        let text = String(decoding: safeData.prefix(maximumResponseBodyBytes), as: UTF8.self)
        let notice = safeData.count > maximumResponseBodyBytes
            ? "\n\n[响应超过显示上限：保留前 \(maximumResponseBodyBytes) 字节，原始响应 \(body.count) 字节；后续内容未显示。]" : ""
        return (statusCode == 200 ? "✓ " : "HTTP \(statusCode): ") + text + notice
    }

    static let emptyBodyMessage = "响应异常：HTTP 200 但响应体为空"

    /// 错误 → 展示文案 (纯函数, 可测): 网络类 = 请求可能已达服务端 → 结果不确定, 可能已消费
    static func describe(error: Error) -> String {
        if isNetworkUncertain(error) {
            return "结果不确定，可能已消费：\(error.localizedDescription)（请求可能已送达，请稍后查询额度确认）"
        }
        return error.localizedDescription
    }

    /// 网络类错误分类 (纯函数, 可测): 超时/断连/连不上/DNS 等 — 请求发出但回包未达, 结果不确定
    static func isNetworkUncertain(_ error: Error) -> Bool {
        guard let ur = error as? URLError else { return false }
        switch ur.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}
