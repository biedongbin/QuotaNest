import Foundation

/// 触发额度刷新/测试: 向服务商发请求
/// 配置从 auth 文件读 (ProviderConfigStore), 协议差异由 manifest 声明
/// 协议: anthropic (Messages API) / openai (Chat Completions), 由 config.refreshProtocol 决定
enum RefreshTrigger {
    /// 上栏测试: 发查询请求 (GET url + header), 看是否返回数据
    static func testQuery(config: ProviderConfig) async -> String? {
        guard !config.queryUrl.isEmpty else { return "未配置查询 url" }
        // 凭证: jwt/cookie 用 queryToken/queryCookie, 其他用 queryKey
        let key = config.queryToken.isEmpty ? (config.queryCookie.isEmpty ? config.queryKey : config.queryCookie) : config.queryToken
        guard !key.isEmpty else { return "未配置查询凭证" }
        // P0: url 非法时 URL(string:) 返回 nil, 强解包会 crash 整个 App
        guard let u = URL(string: config.queryUrl) else { return "查询 url 非法" }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        applyHeaders(&req, config.queryHeader, key: key, protocol: config.refreshProtocol)
        return await send(req)
    }

    /// 下栏测试/触发刷新: 发 chat 请求 (POST url + header + model + prompt)
    static func testRefresh(config: ProviderConfig) async -> String? {
        guard !config.refreshUrl.isEmpty else { return "未配置刷新 url" }
        guard !config.refreshKey.isEmpty else { return "未配置刷新 apiKey" }
        guard !config.testModel.isEmpty else { return "未配置测试模型" } // model 空则供应商拒绝, 窗口不推进
        guard let u = URL(string: config.refreshUrl) else { return "刷新 url 非法" }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        applyHeaders(&req, config.refreshHeader, key: config.refreshKey, protocol: config.refreshProtocol)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.testModel,
            "max_tokens": 50,
            "messages": [["role": "user", "content": config.testPrompt]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req)
    }

    /// 触发额度刷新 (兼容旧调用: 用 auth 文件读配置)
    static func trigger(manifest: ProviderManifest, authFile: URL) async -> String? {
        var config = ProviderConfigStore.read(authFile: authFile, manifest: manifest)
        // auth 文件无 testModel 时回退 manifest 默认, 否则 POST body model 为空不触发计费
        if config.testModel.isEmpty {
            config.testModel = manifest.refreshModel
        }
        return await testRefresh(config: config)
    }

    /// 按协议应用 header: 解析 header 文本 (每行 "k: v"), <key> 占位符替换
    /// anthropic 额外加 anthropic-version (internal 供测试)
    static func applyHeaders(_ req: inout URLRequest, _ headerStr: String, key: String, protocol: String) {
        for line in headerStr.split(separator: "\n") {
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

    private static func send(_ req: URLRequest) async -> String? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "无响应" }
            if http.statusCode == 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                return body.isEmpty ? nil : "✓ \(body.prefix(120))"
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return "HTTP \(http.statusCode): \(body.prefix(120))"
        } catch {
            return error.localizedDescription
        }
    }
}
