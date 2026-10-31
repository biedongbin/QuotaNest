import Foundation

/// 仅负责 API 协议路径，不参与额度查询路径解析。
enum APIEndpoint {
    static func requestURL(baseURL: String, protocolName: String) -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return "" }
        let suffix = protocolName == "anthropic" ? "/messages" : "/chat/completions"
        if base.hasSuffix(suffix) { return base }
        return base.hasSuffix("/v1") ? base + suffix : base + "/v1" + suffix
    }

    static func baseURL(from endpoint: String) -> String {
        for suffix in ["/chat/completions", "/messages"] where endpoint.hasSuffix(suffix) {
            return String(endpoint.dropLast(suffix.count))
        }
        return endpoint
    }
}
